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

/// 检测 DashScope ASR 在静默时回传的 corpus.text（热词提示文本）
func isCorpusLeak(_ text: String) -> Bool {
    text.contains("本次对话涉及") || text.contains("专有名词可能出现")
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

    @Published var llmRefineEnabled: Bool {
        didSet { UserDefaults.standard.set(llmRefineEnabled, forKey: "llm_refine_enabled") }
    }
    @Published var refineStyle: RefineStyle {
        didSet { UserDefaults.standard.set(refineStyle.rawValue, forKey: "refine_style") }
    }
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
    private var streamingHasFinished = false
    private var committedSentences: [String] = []
    private var streamingResult: String = ""
    private var wavFileURL: URL?
    private var recordingDuration: TimeInterval = 0
    private var recordingStartTime: Date?
    private var lastPartialText: String = ""
    private var lastPartialChangeTime: Date = Date()
    private var streamingStallTimer: Timer?
    private var safetyTimeoutWork: DispatchWorkItem?
    private var sentenceRefineCache: [String: String] = [:]
    private var pendingRefineCount = 0

    init() {
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let selectedHotkey = HotkeyOption(rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? "rightOption") ?? .rightOption
        let initialAccessibility = AXIsProcessTrusted()
        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        // LLM refinement defaults: enabled
        let llmEnabled = UserDefaults.standard.object(forKey: "llm_refine_enabled") as? Bool ?? true
        let style = RefineStyle(rawValue: UserDefaults.standard.string(forKey: "refine_style") ?? "default") ?? .default

        self.hasCompletedSetup = hasCompletedSetup
        self.selectedHotkey = selectedHotkey
        self.hasAccessibility = initialAccessibility
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID
        self.llmRefineEnabled = llmEnabled
        self.refineStyle = style

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
        // Prevent double-entry: hotkey can fire twice before isRecording is set
        guard !isRecording else { return }
        isRecording = true

        let t0 = CFAbsoluteTimeGetCurrent()
        viLog("startRecording() entered")
        // Cancel any leftover safety timeout from a previous session
        safetyTimeoutWork?.cancel()
        safetyTimeoutWork = nil
        // Always re-check live instead of relying on cached value
        hasAccessibility = AXIsProcessTrusted()
        viLog("AXIsProcessTrusted() = \(hasAccessibility)")
        if !hasAccessibility {
            viLog("AX permission not granted, prompting user")
            overlayManager.showError(title: "辅助功能权限未授予", suggestion: "请在系统设置中允许 SpeakLow 控制电脑")
            openAccessibilitySettings()
            // 不阻断录音，继续录音（权限可能在录音期间被授予）
        }
        guard ensureMicrophoneAccess() else {
            isRecording = false
            return
        }
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
                    self.statusText = "语音功能异常"
                    self.errorMessage = "语音功能出了问题"
                    NSSound(named: "Basso")?.play()
                    self.overlayManager.showError(
                        title: "语音功能出了问题",
                        suggestion: "请退出并重新打开 SpeakLow"
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
        self.streamingHasFinished = false
        self.streamingResult = ""
        self.wavFileURL = nil
        self.recordingDuration = 0
        self.recordingStartTime = nil
        self.sentenceRefineCache = [:]
        self.pendingRefineCount = 0

        // Set up streaming audio callback
        audioRecorder.onStreamingAudioChunk = { [weak self] chunk in
            self?.streamingService?.sendAudioChunk(chunk)
        }

        // Start streaming connection to bridge
        streaming.start()
        // Preview panel auto-shows on first partial text
        viLog("Streaming mode: initialized")

        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                initTimer.cancel()
                os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                self.recordingStartTime = Date()
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
                self.statusText = "麦克风没有声音"
                self.errorMessage = "麦克风没有声音"
                NSSound(named: "Basso")?.play()
                self.overlayManager.showError(
                    title: "麦克风没有声音",
                    suggestion: "请检查麦克风是否正常连接"
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
        streamingStallTimer?.invalidate()
        streamingStallTimer = nil

        let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0.0
        if elapsed < 0.2 {
            viLog("stopStreamingRecording: 录音时长 \(Int(elapsed * 1000))ms < 200ms，丢弃")
            audioRecorder.onStreamingAudioChunk = nil
            _ = audioRecorder.stopRecording()
            recordingStartTime = nil
            recordingDuration = 0
            wavFileURL = nil
            isRecording = false
            safetyTimeoutWork?.cancel()
            safetyTimeoutWork = nil
            streamingHasFinished = true
            streamingService?.disconnect()
            streamingService = nil
            isStreaming = false
            overlayManager.dismiss()
            return
        }

        if let start = recordingStartTime {
            recordingDuration = Date().timeIntervalSince(start)
        } else {
            recordingDuration = 0
        }
        recordingStartTime = nil

        // Stop recording (flushes remaining audio buffer)
        wavFileURL = audioRecorder.stopRecording()
        isRecording = false

        // Tell streaming service we're done sending audio
        streamingService?.stop()
        viLog("stopStreamingRecording: stop message sent to bridge")

        // Show finalizing indicator
        overlayManager.slideUpToNotch { [weak self] in
            self?.overlayManager.showTranscribing()
        }
        statusText = "正在完成..."

        // Safety timeout: if streamingDidFinish doesn't fire within 5s, force-finish
        safetyTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStreaming else { return }
            viLog("stopStreamingRecording: safety timeout — force-finishing streaming session")
            self.streamingDidFinish()
        }
        safetyTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    // MARK: - Transcription

    func stopAndTranscribe() {
        viLog(" stopAndTranscribe() entered")
        os_log(.info, log: recordingLog, "stopAndTranscribe() entered")
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        guard let fileURL = audioRecorder.stopRecording() else {
            os_log(.error, log: recordingLog, "stopRecording() returned nil — no audio file")
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

                        if self.llmRefineEnabled {
                            self.overlayManager.updatePreviewText("✨ 正在优化...")
                            viLog("Batch: starting LLM refine, style=\(self.refineStyle.rawValue)")
                            let style = self.refineStyle
                            Task {
                                let refined = await TextRefineService.refine(text: trimmed, style: style)
                                await MainActor.run {
                                    self.batchInsertAndFinish(originalText: trimmed, finalText: refined)
                                }
                            }
                        } else {
                            self.batchInsertAndFinish(originalText: trimmed, finalText: trimmed)
                        }
                    }

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
                }
            }
        }
    }

    private func userFriendlyTranscriptionError(_ error: Error) -> (title: String, suggestion: String) {
        // Extract the full error chain for keyword matching
        let desc: String
        if let txErr = error as? TranscriptionError {
            switch txErr {
            case .submissionFailed(let msg): desc = msg.lowercased()
            case .transcriptionFailed(let msg): desc = msg.lowercased()
            case .transcriptionTimedOut: desc = "timeout"
            case .pollFailed(let msg): desc = msg.lowercased()
            }
        } else {
            desc = error.localizedDescription.lowercased()
        }

        // 1. No network / DNS failure
        if desc.contains("no such host") || desc.contains("dns") ||
           desc.contains("name resolution") || desc.contains("cannot find the server") ||
           desc.contains("not connected to the internet") ||
           desc.contains("network is unreachable") || desc.contains("no route to host") {
            return ("没有网络连接", "请检查 Wi-Fi 或网络设置")
        }

        // 2. Network connectivity issues
        if desc.contains("timed out") || desc.contains("timeout") {
            return ("网络太慢了", "请检查网络连接后再试")
        }
        if desc.contains("network") || desc.contains("connection refused") ||
           desc.contains("connection reset") || desc.contains("connection was lost") ||
           desc.contains("socket is not connected") {
            return ("网络连接断了", "请检查网络连接后再试")
        }

        // 3. Bridge (local ASR service) down
        if desc.contains("18089") || desc.contains("localhost") {
            return ("语音功能出了问题", "请退出并重新打开 SpeakLow")
        }

        // 4. API auth / quota errors
        if desc.contains("401") || desc.contains("403") ||
           desc.contains("unauthorized") || desc.contains("invalid api") ||
           desc.contains("authentication") || desc.contains("api key") {
            return ("API 密钥有问题", "请检查 DashScope API Key 配置")
        }
        if desc.contains("429") || desc.contains("rate limit") || desc.contains("quota") ||
           desc.contains("too many requests") {
            return ("用得太频繁了", "请稍等一会儿再试")
        }

        // 5. Server-side error (DashScope 500 etc.)
        if desc.contains("status 500") || desc.contains("internal server error") ||
           desc.contains("502") || desc.contains("503") || desc.contains("service unavailable") {
            return ("识别服务出了点问题", "通常很快恢复，请稍后再试")
        }

        // 6. Generic fallback
        return ("出了点问题", "请重试，如果反复出现请重启应用")
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

        // Start stall detection: check every 3s if partial text has been stuck
        lastPartialText = ""
        lastPartialChangeTime = Date()
        streamingStallTimer?.invalidate()
        streamingStallTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, self.isStreaming else { return }
            let stalledFor = Date().timeIntervalSince(self.lastPartialChangeTime)
            if stalledFor > 10 && !self.lastPartialText.isEmpty {
                viLog("Streaming: partial text stuck for \(Int(stalledFor))s, force-finishing")
                self.streamingStallTimer?.invalidate()
                self.streamingStallTimer = nil
                // Force-finish: treat current committed text as final
                self.streamingDidFinish()
            }
        }
    }

    func streamingDidReceivePartial(text: String) {
        // 拦截 corpus leak：DashScope 在静默时会把 session config 中的热词提示文本回传
        if isCorpusLeak(text) { return }
        viLog("Streaming partial: \(text.prefix(40))")
        let display = committedSentences.joined() + text
        overlayManager.updatePreviewText(display)

        // Track stall: if partial text hasn't changed for 10s, the stream is stuck
        if text != lastPartialText {
            lastPartialText = text
            lastPartialChangeTime = Date()
        }
    }

    func streamingDidReceiveSentence(text: String) {
        if isCorpusLeak(text) { return }
        viLog("Streaming sentence_end: '\(text.prefix(40))'")
        committedSentences.append(text)
        let display = committedSentences.joined()
        overlayManager.updatePreviewText(display)

        guard llmRefineEnabled else { return }
        pendingRefineCount += 1
        let style = refineStyle
        Task {
            let refined = await TextRefineService.refine(text: text, style: style)
            await MainActor.run {
                self.sentenceRefineCache[text] = refined
                self.pendingRefineCount = max(0, self.pendingRefineCount - 1)
                viLog("Sentence pre-refine done: '\(text.prefix(20))' → '\(refined.prefix(20))'")
            }
        }
    }

    func streamingDidFinish() {
        guard isStreaming else { return } // Prevent double-fire from safety timeout
        streamingHasFinished = true
        viLog("Streaming: finished")

        isStreaming = false
        streamingStallTimer?.invalidate()
        streamingStallTimer = nil
        streamingService?.disconnect()
        streamingService = nil
        audioRecorder.onStreamingAudioChunk = nil

        transcribingIndicatorTask?.cancel()
        transcribingIndicatorTask = nil

        var fullText = committedSentences.joined()
        if fullText.isEmpty && !lastPartialText.isEmpty {
            viLog("Streaming: no committed sentences but has partial '\(lastPartialText.prefix(40))', using as final")
            fullText = lastPartialText
        }

        if fullText.isEmpty {
            statusText = "未检测到语音"
            NSSound(named: "Basso")?.play()
            overlayManager.dismissPreviewPanel()
            overlayManager.showError(title: "未检测到语音", suggestion: "请靠近麦克风说话")
            return
        }

        // Save streaming result as fallback for sync re-transcribe failure.
        streamingResult = fullText

        let duration = recordingDuration
        let wavURL = wavFileURL
        // Skip qwen3 sync re-transcription when streaming already uses qwen3 (same model family, minimal benefit)
        let streamModel = UserDefaults.standard.string(forKey: "asr_stream_model") ?? "qwen3-asr-flash-realtime"
        let shouldTryQwen3 = !streamModel.contains("qwen3") && wavURL != nil && duration < 300

        if shouldTryQwen3, let url = wavURL {
            let timeout = min(15.0, max(3.0, duration * 0.3))
            viLog("Streaming: launching qwen3 sync ASR, timeout=\(String(format: "%.1f", timeout))s, duration=\(String(format: "%.1f", duration))s")
            overlayManager.updatePreviewText("✨ 优化识别中...")

            Task {
                let syncResult = await self.transcribeSyncWithFallback(
                    wavURL: url,
                    fallbackText: self.streamingResult,
                    timeout: timeout
                )
                await MainActor.run {
                    self.applyFinalTranscript(syncResult.text, usePreRefined: syncResult.usedFallback)
                }
            }
        } else {
            if !shouldTryQwen3 {
                viLog("Streaming: skipping qwen3 (duration=\(String(format: "%.0f", duration))s, wavURL=\(wavURL?.path ?? "nil"))")
            }
            applyFinalTranscript(fullText, usePreRefined: true)
        }
    }

    private func transcribeSyncWithFallback(
        wavURL: URL,
        fallbackText: String,
        timeout: TimeInterval
    ) async -> (text: String, usedFallback: Bool) {
        let bridgeURL = URL(string: "http://127.0.0.1:18089/v1/transcribe-sync")!

        do {
            let data = try Data(contentsOf: wavURL)
            let result = try await withTimeout(seconds: timeout) {
                try await self.postMultipartAudio(to: bridgeURL, audioData: data)
            }
            if let text = result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                viLog("qwen3 sync: got '\(text.prefix(40))' (used qwen3 result)")
                return (text, false)
            }
        } catch {
            viLog("qwen3 sync: failed or timeout: \(error.localizedDescription), using streaming fallback")
        }

        return (fallbackText, true)
    }

    private func postMultipartAudio(to url: URL, audioData: Data) async throws -> String? {
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "TranscribeSync",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "TranscribeSync",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(detail)"]
            )
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["text"] as? String
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func applyFinalTranscript(_ text: String, usePreRefined: Bool = false) {
        lastTranscript = text

        if llmRefineEnabled {
            if usePreRefined && !sentenceRefineCache.isEmpty {
                let refined = committedSentences.map { sentenceRefineCache[$0] ?? $0 }.joined()
                if !refined.isEmpty {
                    viLog("applyFinalTranscript: using pre-refined sentences, pending=\(pendingRefineCount)")
                    insertAndFinish(originalText: text, finalText: refined)
                    return
                }
            }

            overlayManager.updatePreviewText("✨ 正在优化...")
            viLog("applyFinalTranscript: starting LLM refine, style=\(refineStyle.rawValue)")
            let style = refineStyle
            Task {
                let refined = await TextRefineService.refine(text: text, style: style)
                await MainActor.run {
                    self.insertAndFinish(originalText: text, finalText: refined)
                }
            }
        } else {
            insertAndFinish(originalText: text, finalText: text)
        }
    }

    /// Shared insertion logic for both streaming and batch paths.
    private func insertAndFinish(originalText: String, finalText: String) {
        let changed = finalText != originalText
        if changed {
            viLog("LLM refined: '\(originalText.prefix(30))' → '\(finalText.prefix(30))'")
            lastTranscript = finalText
        }

        viLog("Inserting text, length=\(finalText.count)")
        let result = TextInserter.insert(finalText)
        viLog("Insert result=\(result)")

        switch result {
        case .insertedViaAX:
            statusText = "已插入: \(finalText.prefix(20))..."
        case .pastedViaClipboard:
            statusText = "已粘贴: \(finalText.prefix(20))..."
        case .copiedToClipboard:
            statusText = "已复制到剪贴板（请手动粘贴）"
        }

        overlayManager.dismissPreviewPanel()
        if result == .copiedToClipboard {
            NSSound(named: "Purr")?.play()
            overlayManager.showTextResult(finalText)
            openAccessibilitySettings()
        } else {
            NSSound(named: "Glass")?.play()
            overlayManager.showDone()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if result != .copiedToClipboard { self.overlayManager.dismiss() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if self.statusText.hasPrefix("已插入") || self.statusText.hasPrefix("已粘贴") ||
               self.statusText.hasPrefix("已复制") || self.statusText == "未检测到语音" {
                self.statusText = "Ready"
            }
        }
    }

    /// Batch-mode insertion with notification fallback for copiedToClipboard.
    private func batchInsertAndFinish(originalText: String, finalText: String) {
        let changed = finalText != originalText
        if changed {
            viLog("LLM refined (batch): '\(originalText.prefix(30))' → '\(finalText.prefix(30))'")
            lastTranscript = finalText
        }

        viLog("Batch: inserting text, length=\(finalText.count)")
        let insertResult = TextInserter.insert(finalText)
        viLog("Batch: insert result=\(insertResult)")

        switch insertResult {
        case .insertedViaAX:
            statusText = "已插入: \(finalText.prefix(20))..."
            NSSound(named: "Glass")?.play()
            overlayManager.showDone()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.overlayManager.dismiss()
            }
        case .pastedViaClipboard:
            statusText = "已粘贴: \(finalText.prefix(20))..."
            NSSound(named: "Glass")?.play()
            overlayManager.showDone()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.overlayManager.dismiss()
            }
        case .copiedToClipboard:
            statusText = "已复制到剪贴板（请手动粘贴）"
            NSSound(named: "Purr")?.play()
            overlayManager.showTextResult(finalText)
            openAccessibilitySettings()
        }
    }

    func streamingDidFail(error: Error) {
        guard !streamingHasFinished else {
            viLog("Streaming: close callback after finish, ignoring")
            return
        }

        viLog("Streaming FAILED: \(error.localizedDescription), falling back to batch mode")

        isStreaming = false
        streamingStallTimer?.invalidate()
        streamingStallTimer = nil
        streamingService?.disconnect()
        streamingService = nil
        audioRecorder.onStreamingAudioChunk = nil
        overlayManager.dismissPreviewPanel()

        // Check if this is an unrecoverable error (no network, auth, etc.)
        // In these cases batch fallback will also fail, so show error immediately.
        let desc = error.localizedDescription.lowercased()
        let isNetworkError = desc.contains("no such host") || desc.contains("dns") ||
            desc.contains("not connected to the internet") || desc.contains("network is unreachable")
        let isAuthError = desc.contains("401") || desc.contains("403") || desc.contains("unauthorized")

        if isNetworkError || isAuthError {
            viLog("Streaming: unrecoverable error, stopping recording and showing error")
            _ = audioRecorder.stopRecording()
            isRecording = false
            let (errTitle, errSuggestion) = userFriendlyTranscriptionError(error)
            statusText = errTitle
            errorMessage = error.localizedDescription
            NSSound(named: "Basso")?.play()
            overlayManager.showError(title: errTitle, suggestion: errSuggestion)
            return
        }

        // Recoverable: keep recording for batch fallback.
        // When user releases hotkey, handleHotkeyUp will call stopAndTranscribe().
    }
}
