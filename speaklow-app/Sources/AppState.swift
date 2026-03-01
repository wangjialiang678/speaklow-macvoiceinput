import Foundation
import Combine
import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement
import ApplicationServices
import os.log

private let recordingLog = OSLog(subsystem: "com.speaklow.app", category: "Recording")

// File-based logger for debugging (unified log not visible for unsigned apps)
func viLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    let logPath = NSHomeDirectory() + "/Library/Logs/SpeakLow.log"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
    NSLog("[SpeakLow] %@", message)
}

final class AppState: ObservableObject, @unchecked Sendable {
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let transcribingIndicatorDelay: TimeInterval = 1.0

    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var selectedHotkey: HotkeyOption {
        didSet {
            UserDefaults.standard.set(selectedHotkey.rawValue, forKey: "hotkey_option")
            restartHotkeyMonitoring()
        }
    }

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var lastTranscript: String = ""
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"
    @Published var hasAccessibility = false
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    /// Set by AppDelegate after init; used for auto-restart on health check failure.
    var bridgeManager: ASRBridgeManager?
    private var accessibilityTimer: Timer?
    private var audioLevelCancellable: AnyCancellable?
    private var transcribingIndicatorTask: Task<Void, Never>?
    private var audioDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    // Streaming state
    private var streamingService: StreamingTranscriptionService?
    private var isStreaming = false
    private var committedSentences: [String] = []

    init() {
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let selectedHotkey = HotkeyOption(rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? "rightOption") ?? .rightOption
        let initialAccessibility = AXIsProcessTrusted()
        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        self.hasCompletedSetup = hasCompletedSetup
        self.selectedHotkey = selectedHotkey
        self.hasAccessibility = initialAccessibility
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID

        refreshAvailableMicrophones()
        installAudioDeviceListener()

        viLog("AppState init complete. hotkey=\(selectedHotkey.rawValue), setup=\(hasCompletedSetup), accessibility=\(initialAccessibility)")
    }

    deinit {
        removeAudioDeviceListener()
    }

    private func removeAudioDeviceListener() {
        guard let block = audioDeviceListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        audioDeviceListenerBlock = nil
    }

    // MARK: - Audio Storage

    static func audioStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "SpeakLow"
        let audioDir = appSupport.appendingPathComponent("\(appName)/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }

    // MARK: - Accessibility

    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        hasAccessibility = AXIsProcessTrusted()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hasAccessibility = AXIsProcessTrusted()
            }
        }
    }

    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Launch at Login

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let current = SMAppService.mainApp.status == .enabled
            if current != launchAtLogin {
                launchAtLogin = current
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        let current = SMAppService.mainApp.status == .enabled
        if current != launchAtLogin {
            launchAtLogin = current
        }
    }

    // MARK: - Microphones

    func refreshAvailableMicrophones() {
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    private func installAudioDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAvailableMicrophones()
            }
        }
        audioDeviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    // MARK: - Hotkey Monitoring

    func startHotkeyMonitoring() {
        hotkeyManager.onKeyDown = { [weak self] in
            DispatchQueue.main.async {
                self?.handleHotkeyDown()
            }
        }
        hotkeyManager.onKeyUp = { [weak self] in
            DispatchQueue.main.async {
                self?.handleHotkeyUp()
            }
        }
        hotkeyManager.start(option: selectedHotkey)
    }

    private func restartHotkeyMonitoring() {
        hotkeyManager.start(option: selectedHotkey)
    }

    private func handleHotkeyDown() {
        viLog("handleHotkeyDown() fired, isRecording=\(isRecording), isTranscribing=\(isTranscribing)")
        guard !isRecording && !isTranscribing else { return }
        startRecording()
    }

    private func handleHotkeyUp() {
        viLog("handleHotkeyUp() fired, isRecording=\(isRecording), isStreaming=\(isStreaming)")
        guard isRecording else { return }

        if isStreaming {
            stopStreamingRecording()
        } else {
            stopAndTranscribe()
        }
    }

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        if isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        let t0 = CFAbsoluteTimeGetCurrent()
        viLog("startRecording() entered")
        // Always re-check live instead of relying on cached value
        hasAccessibility = AXIsProcessTrusted()
        viLog("AXIsProcessTrusted() = \(hasAccessibility)")
        guard hasAccessibility else {
            errorMessage = "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
            statusText = "No Accessibility"
            showAccessibilityAlert()
            return
        }
        guard ensureMicrophoneAccess() else { return }
        beginRecording()
        os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    private func ensureMicrophoneAccess() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecording()
                    } else {
                        self?.errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
                        self?.statusText = "No Microphone"
                        self?.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            showMicrophonePermissionAlert()
            return false
        }
    }

    private func beginRecording() {
        os_log(.info, log: recordingLog, "beginRecording() entered")
        errorMessage = nil
        isRecording = true
        statusText = "Starting..."

        // Pre-flight: check if asr-bridge is reachable; auto-restart if not
        let healthService = TranscriptionService()
        Task {
            var bridgeHealthy = await healthService.checkHealth()

            if !bridgeHealthy, let bridge = self.bridgeManager {
                viLog("Pre-flight: bridge unhealthy, attempting auto-restart...")
                await MainActor.run {
                    self.statusText = "正在恢复服务..."
                    self.overlayManager.showInitializing()
                }
                bridgeHealthy = await bridge.ensureRunning()
                if bridgeHealthy {
                    viLog("Pre-flight: bridge auto-restarted successfully")
                } else {
                    viLog("Pre-flight: bridge auto-restart failed")
                }
            }

            if !bridgeHealthy {
                viLog("Pre-flight: asr-bridge health check failed")
                await MainActor.run {
                    self.isRecording = false
                    self.statusText = "服务异常"
                    self.errorMessage = "语音服务未启动"
                    NSSound(named: "Basso")?.play()
                    self.overlayManager.showError(
                        title: "语音服务未启动",
                        suggestion: "请重启 SpeakLow"
                    )
                }
                return
            }
            await MainActor.run { self._beginRecordingAfterHealthCheck() }
        }
    }

    private func _beginRecordingAfterHealthCheck() {
        // Show initializing dots only if engine takes longer than 0.5s to start
        var overlayShown = false
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        initTimer.schedule(deadline: .now() + 0.5)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.overlayManager.showInitializing()
        }
        initTimer.resume()

        // Set up streaming
        let streaming = StreamingTranscriptionService()
        streaming.delegate = self
        self.streamingService = streaming
        self.isStreaming = true
        self.committedSentences = []

        // Set up streaming audio callback
        audioRecorder.onStreamingAudioChunk = { [weak self] chunk in
            self?.streamingService?.sendAudioChunk(chunk)
        }

        // Start streaming connection to bridge
        streaming.start()
        TextInserter.beginStreamingSession()
        viLog("Streaming mode: initialized")

        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                initTimer.cancel()
                os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                self.statusText = "Recording..."
                if overlayShown {
                    self.overlayManager.transitionToRecording()
                } else {
                    self.overlayManager.showRecording()
                }
                overlayShown = true
                NSSound(named: "Tink")?.play()
            }
        }

        audioRecorder.onSilenceTimeout = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                viLog("Silence timeout — stopping recording and showing error")
                initTimer.cancel()
                self.audioLevelCancellable?.cancel()
                self.audioLevelCancellable = nil
                self.isRecording = false
                self.statusText = "麦克风无响应"
                self.errorMessage = "麦克风无响应"
                self.audioRecorder.cleanup()
                NSSound(named: "Basso")?.play()
                self.overlayManager.showError(
                    title: "麦克风无响应",
                    suggestion: "请检查麦克风或重启应用"
                )
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                try self.audioRecorder.startRecording(deviceUID: deviceUID)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                DispatchQueue.main.async {
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                }
            } catch {
                DispatchQueue.main.async {
                    initTimer.cancel()
                    self.isRecording = false
                    self.errorMessage = self.formattedRecordingStartError(error)
                    self.statusText = "Error"
                    self.overlayManager.dismiss()
                }
            }
        }
    }

    private func formattedRecordingStartError(_ error: Error) -> String {
        if let recorderError = error as? AudioRecorderError {
            return "Failed to start recording: \(recorderError.localizedDescription)"
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("operation couldn't be completed") || lower.contains("operation could not be completed") {
            return "Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected."
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }

        return "Failed to start recording: \(error.localizedDescription)"
    }

    // MARK: - Streaming Recording

    private func stopStreamingRecording() {
        viLog("stopStreamingRecording() entered")
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // Stop recording (flushes remaining audio buffer)
        _ = audioRecorder.stopRecording()
        isRecording = false

        // Tell streaming service we're done sending audio
        streamingService?.stop()

        // Show finalizing indicator
        overlayManager.slideUpToNotch { [weak self] in
            self?.overlayManager.showTranscribing()
        }
        statusText = "正在完成..."
    }

    // MARK: - Transcription

    func stopAndTranscribe() {
        viLog(" stopAndTranscribe() entered")
        os_log(.info, log: recordingLog, "stopAndTranscribe() entered")
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        guard let fileURL = audioRecorder.stopRecording() else {
            os_log(.error, log: recordingLog, "stopRecording() returned nil — no audio file")
            audioRecorder.cleanup()
            errorMessage = "No audio recorded"
            isRecording = false
            statusText = "Error"
            return
        }

        viLog("Audio file: \(fileURL.path)")
        os_log(.info, log: recordingLog, "Audio file: %{public}@", fileURL.path)

        // Check file size
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        os_log(.info, log: recordingLog, "Audio file size: %d bytes", fileSize)

        isRecording = false
        isTranscribing = true
        statusText = "Transcribing..."
        errorMessage = nil
        NSSound(named: "Pop")?.play()
        overlayManager.slideUpToNotch { }

        transcribingIndicatorTask?.cancel()
        let indicatorDelay = transcribingIndicatorDelay
        transcribingIndicatorTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(indicatorDelay * 1_000_000_000))
                let shouldShowTranscribing = self?.isTranscribing ?? false
                guard shouldShowTranscribing else { return }
                await MainActor.run { [weak self] in
                    self?.overlayManager.showTranscribing()
                }
            } catch {}
        }

        let transcriptionService = TranscriptionService()
        viLog("Starting transcription, file size=\(fileSize) bytes")
        os_log(.info, log: recordingLog, "Starting transcription task...")

        Task {
            do {
                let rawTranscript = try await transcriptionService.transcribe(fileURL: fileURL)
                let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                viLog("Transcription result: '\(trimmed)' (length=\(trimmed.count))")
                os_log(.info, log: recordingLog, "Transcription result: '%{public}@' (length=%d)", trimmed, trimmed.count)

                await MainActor.run {
                    self.transcribingIndicatorTask?.cancel()
                    self.transcribingIndicatorTask = nil
                    self.isTranscribing = false

                    if trimmed.isEmpty {
                        viLog("Empty transcription — nothing to insert")
                        self.statusText = "未检测到语音"
                        NSSound(named: "Basso")?.play()
                        self.overlayManager.showError(
                            title: "未检测到语音",
                            suggestion: "请靠近麦克风说话"
                        )
                    } else {
                        self.lastTranscript = trimmed

                        viLog("Calling TextInserter.insert()...")
                        let insertResult = TextInserter.insert(trimmed)
                        viLog("TextInserter result: \(insertResult)")

                        switch insertResult {
                        case .insertedViaAX:
                            self.statusText = "已插入: \(trimmed.prefix(20))..."
                            NSSound(named: "Glass")?.play()
                        case .pastedViaClipboard:
                            self.statusText = "已粘贴: \(trimmed.prefix(20))..."
                            NSSound(named: "Glass")?.play()
                        case .copiedToClipboard:
                            self.statusText = "已复制到剪贴板（请手动粘贴）"
                            NSSound(named: "Purr")?.play()
                            self.showNotification(
                                title: "已复制到剪贴板",
                                body: "无法自动插入，请按 Cmd+V 粘贴：\(trimmed.prefix(50))"
                            )
                        }

                        self.overlayManager.showDone()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            self.overlayManager.dismiss()
                        }
                    }

                    self.audioRecorder.cleanup()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if self.statusText.hasPrefix("已插入") || self.statusText.hasPrefix("已粘贴") ||
                           self.statusText.hasPrefix("已复制") || self.statusText.hasPrefix("识别失败") ||
                           self.statusText == "Nothing to transcribe" {
                            self.statusText = "Ready"
                        }
                    }
                }
            } catch {
                viLog("Transcription FAILED: \(error.localizedDescription)")

                // If it looks like bridge died, try to auto-restart for next time
                let desc = error.localizedDescription.lowercased()
                if desc.contains("18089") || desc.contains("localhost") || desc.contains("connection refused") {
                    if let bridge = self.bridgeManager {
                        viLog("Bridge appears down — attempting auto-restart for next recording...")
                        let restarted = await bridge.ensureRunning()
                        viLog("Bridge auto-restart result: \(restarted)")
                    }
                }

                let (errTitle, errSuggestion) = self.userFriendlyTranscriptionError(error)
                await MainActor.run {
                    self.transcribingIndicatorTask?.cancel()
                    self.transcribingIndicatorTask = nil
                    self.errorMessage = error.localizedDescription
                    self.isTranscribing = false
                    self.statusText = errTitle
                    NSSound(named: "Basso")?.play()
                    self.overlayManager.showError(
                        title: errTitle,
                        suggestion: errSuggestion
                    )
                    self.audioRecorder.cleanup()
                }
            }
        }
    }

    private func userFriendlyTranscriptionError(_ error: Error) -> (title: String, suggestion: String) {
        let desc = error.localizedDescription.lowercased()

        if let txErr = error as? TranscriptionError {
            switch txErr {
            case .transcriptionTimedOut:
                return ("网络连接超时", "请检查网络连接")
            case .submissionFailed(let msg):
                if msg.lowercased().contains("network") || msg.lowercased().contains("connection") {
                    return ("网络连接失败", "请检查网络连接")
                }
                if msg.contains("18089") || msg.contains("localhost") {
                    return ("语音服务未响应", "请重启 SpeakLow")
                }
                return ("识别服务异常", "请稍后重试")
            case .transcriptionFailed:
                return ("识别服务异常", "请稍后重试")
            case .pollFailed:
                return ("识别结果异常", "请稍后重试")
            }
        }

        if desc.contains("timed out") || desc.contains("timeout") {
            return ("网络连接超时", "请检查网络连接")
        }
        if desc.contains("network") || desc.contains("connection") {
            return ("网络连接失败", "请检查网络连接")
        }

        return ("识别失败", "请稍后重试")
    }

    // MARK: - Notifications

    private func showNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Alerts

    func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "SpeakLow cannot record audio without Microphone access.\n\nGo to System Settings > Privacy & Security > Microphone and enable SpeakLow."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            if let url = settingsURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "SpeakLow cannot type transcriptions without Accessibility access.\n\nGo to System Settings > Privacy & Security > Accessibility and enable SpeakLow."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }
}

// MARK: - StreamingTranscriptionDelegate

extension AppState: StreamingTranscriptionDelegate {
    func streamingDidStart() {
        viLog("Streaming: bridge connected, ready to receive audio")
    }

    func streamingDidReceivePartial(text: String) {
        viLog("Streaming partial: \(text.prefix(40))")
        overlayManager.updatePartialText(text)
    }

    func streamingDidReceiveSentence(text: String) {
        viLog("Streaming sentence_end: '\(text.prefix(40))'")
        committedSentences.append(text)
        overlayManager.updatePartialText("")

        // Immediately paste this sentence into the target app
        let result = TextInserter.insertSentence(text)
        viLog("Streaming: sentence paste result=\(result)")
    }

    func streamingDidFinish() {
        viLog("Streaming: finished")

        isStreaming = false
        streamingService?.disconnect()
        streamingService = nil
        audioRecorder.onStreamingAudioChunk = nil
        TextInserter.endStreamingSession()

        transcribingIndicatorTask?.cancel()
        transcribingIndicatorTask = nil

        let fullText = committedSentences.joined()
        if fullText.isEmpty {
            statusText = "未检测到语音"
            NSSound(named: "Basso")?.play()
            overlayManager.showError(title: "未检测到语音", suggestion: "请靠近麦克风说话")
        } else {
            lastTranscript = fullText
            statusText = "已插入: \(fullText.prefix(20))..."
            NSSound(named: "Glass")?.play()
            overlayManager.showDone()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.overlayManager.dismiss()
            }
        }

        audioRecorder.cleanup()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if self.statusText.hasPrefix("已插入") || self.statusText.hasPrefix("已粘贴") ||
               self.statusText == "未检测到语音" {
                self.statusText = "Ready"
            }
        }
    }

    func streamingDidFail(error: Error) {
        viLog("Streaming FAILED: \(error.localizedDescription), falling back to batch mode")

        isStreaming = false
        streamingService?.disconnect()
        streamingService = nil
        audioRecorder.onStreamingAudioChunk = nil
        TextInserter.endStreamingSession()

        // Don't stop recording — audio continues writing to file for batch fallback.
        // When user releases hotkey, handleHotkeyUp will call stopAndTranscribe().
    }
}
