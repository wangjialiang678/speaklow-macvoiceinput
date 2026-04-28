import Foundation
import Combine
import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement
import ApplicationServices
import os.log

private let recordingLog = OSLog(subsystem: "com.speaklow.app", category: "Recording")

// 日志轮转：超过 5MB 时将旧日志移到 .1.log
private func rotateLogIfNeeded() {
    let logPath = NSHomeDirectory() + "/Library/Logs/SpeakLow.log"
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
          let size = attrs[.size] as? Int, size > 5 * 1024 * 1024 else { return }
    let backupPath = logPath + ".1.log"
    try? FileManager.default.removeItem(atPath: backupPath)
    try? FileManager.default.moveItem(atPath: logPath, toPath: backupPath)
    viLog("日志已轮转（旧日志保存为 SpeakLow.log.1.log）")
}

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
    if text.contains("本次对话涉及") || text.contains("专有名词可能出现") {
        return true
    }
    // 短文本前缀匹配：ASR 在用户沉默时可能只输出 corpus header 的开头（如"本次"、"本次对话"）
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= 8 && "本次对话涉及以下".hasPrefix(trimmed) && !trimmed.isEmpty {
        return true
    }
    return false
}

final class AppState: ObservableObject, @unchecked Sendable {
    private let selectedMicrophoneStorageKey = "selected_microphone_id"

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

    @Published var asrMode: ASRMode {
        didSet {
            UserDefaults.standard.set(asrMode.rawValue, forKey: "asr_mode")
            viLog("ASR mode: \(oldValue.rawValue) → \(asrMode.rawValue)")
            strategy = Self.makeStrategy(for: asrMode)
            // Bridge 生命周期跟随模式
            if asrMode == .streaming {
                if let bridge = bridgeManager, !bridge.isRunning {
                    try? bridge.start()
                }
                bridgeManager?.startHealthMonitor()
            } else {
                bridgeManager?.stopHealthMonitor()
                bridgeManager?.stop()
            }
        }
    }

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

    // MARK: - 音效音量配置
    @Published var soundVolumeStart: Float {
        didSet { UserDefaults.standard.set(soundVolumeStart, forKey: "sound_volume_start") }
    }
    @Published var soundVolumeStop: Float {
        didSet { UserDefaults.standard.set(soundVolumeStop, forKey: "sound_volume_stop") }
    }
    @Published var soundVolumeSuccess: Float {
        didSet { UserDefaults.standard.set(soundVolumeSuccess, forKey: "sound_volume_success") }
    }
    @Published var soundVolumeFallback: Float {
        didSet { UserDefaults.standard.set(soundVolumeFallback, forKey: "sound_volume_fallback") }
    }
    @Published var soundVolumeError: Float {
        didSet { UserDefaults.standard.set(soundVolumeError, forKey: "sound_volume_error") }
    }

    // MARK: - Usage Statistics
    @Published var statsTodayCount: Int {
        didSet { UserDefaults.standard.set(statsTodayCount, forKey: "stats_today_count") }
    }
    @Published var statsTodayChars: Int {
        didSet { UserDefaults.standard.set(statsTodayChars, forKey: "stats_today_chars") }
    }
    @Published var statsTodayDuration: TimeInterval {
        didSet { UserDefaults.standard.set(statsTodayDuration, forKey: "stats_today_duration") }
    }
    @Published var statsTotalCount: Int {
        didSet { UserDefaults.standard.set(statsTotalCount, forKey: "stats_total_count") }
    }
    @Published var statsTotalChars: Int {
        didSet { UserDefaults.standard.set(statsTotalChars, forKey: "stats_total_chars") }
    }
    private var statsDate: String {
        didSet { UserDefaults.standard.set(statsDate, forKey: "stats_date") }
    }

    var averageSpeakingSpeed: Int {
        guard statsTodayDuration > 0 else { return 0 }
        return Int(Double(statsTodayChars) / (statsTodayDuration / 60.0))
    }

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    private var strategy: TranscriptionStrategy
    /// Set by AppDelegate after init; used for auto-restart on health check failure.
    var bridgeManager: ASRBridgeManager?
    private var accessibilityTimer: Timer?
    private var audioLevelCancellable: AnyCancellable?
    private var transcribingIndicatorTask: Task<Void, Never>?
    private var audioDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var lastAPIKeyAlertTime: CFAbsoluteTime = 0

    private static func makeStrategy(for mode: ASRMode) -> TranscriptionStrategy {
        switch mode {
        case .batch:
            return BatchStrategy()
        case .streaming:
            return StreamingStrategy()
        }
    }

    private enum RecordingSessionPhase: String {
        case idle
        case hotkeyPressed
        case engineStarted
        case audioReady
    }

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
    private var safetyTimeoutWork: DispatchWorkItem?
    private var engineInitTimer: DispatchSourceTimer?
    private var sentenceRefineCache: [String: String] = [:]
    private var pendingRefineCount = 0
    private var recordingSessionPhase: RecordingSessionPhase = .idle
    private var activeRecordingSessionID: UUID?
    private var hotkeyPressedAt: Date?
    private var captureEngineStartedAt: Date?

    init() {
        rotateLogIfNeeded()
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let selectedHotkey = HotkeyOption(rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? "rightOption") ?? .rightOption
        let initialAccessibility = AXIsProcessTrusted()
        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        // ASR mode defaults: batch
        let asrMode = ASRMode(rawValue: UserDefaults.standard.string(forKey: "asr_mode") ?? "batch") ?? .batch

        // LLM refinement defaults: enabled
        let llmEnabled = UserDefaults.standard.object(forKey: "llm_refine_enabled") as? Bool ?? true
        let style = RefineStyle(rawValue: UserDefaults.standard.string(forKey: "refine_style") ?? "default") ?? .default

        self.asrMode = asrMode
        self.strategy = Self.makeStrategy(for: asrMode)
        self.hasCompletedSetup = hasCompletedSetup
        self.selectedHotkey = selectedHotkey
        self.hasAccessibility = initialAccessibility
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.selectedMicrophoneID = selectedMicrophoneID
        self.llmRefineEnabled = llmEnabled
        self.refineStyle = style

        // 音效音量（UserDefaults 未设置时用默认值）
        let ud = UserDefaults.standard
        self.soundVolumeStart = ud.object(forKey: "sound_volume_start") as? Float ?? 0.8
        self.soundVolumeStop = ud.object(forKey: "sound_volume_stop") as? Float ?? 1.0
        self.soundVolumeSuccess = ud.object(forKey: "sound_volume_success") as? Float ?? 0.1
        self.soundVolumeFallback = ud.object(forKey: "sound_volume_fallback") as? Float ?? 1.0
        self.soundVolumeError = ud.object(forKey: "sound_volume_error") as? Float ?? 1.0

        let today = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
        self.statsDate = UserDefaults.standard.string(forKey: "stats_date") ?? today
        self.statsTodayCount = UserDefaults.standard.integer(forKey: "stats_today_count")
        self.statsTodayChars = UserDefaults.standard.integer(forKey: "stats_today_chars")
        self.statsTodayDuration = UserDefaults.standard.double(forKey: "stats_today_duration")
        self.statsTotalCount = UserDefaults.standard.integer(forKey: "stats_total_count")
        self.statsTotalChars = UserDefaults.standard.integer(forKey: "stats_total_chars")
        if self.statsDate != today {
            self.statsDate = today
            self.statsTodayCount = 0
            self.statsTodayChars = 0
            self.statsTodayDuration = 0
        }

        refreshAvailableMicrophones()
        installAudioDeviceListener()

        viLog("AppState init complete. hotkey=\(selectedHotkey.rawValue), setup=\(hasCompletedSetup), accessibility=\(initialAccessibility)")
        viLog("Sound volumes: start=\(soundVolumeStart), stop=\(soundVolumeStop), success=\(soundVolumeSuccess), fallback=\(soundVolumeFallback), error=\(soundVolumeError)")
    }

    deinit {
        removeAudioDeviceListener()
    }

    /// 播放系统音效，音量由配置控制
    func playSound(_ name: String, volume: Float) {
        guard volume > 0 else {
            viLog("Sound '\(name)' skipped (volume=0)")
            return
        }
        let sound = NSSound(named: NSSound.Name(name))
        sound?.volume = volume
        sound?.play()
        viLog("Sound '\(name)' played at volume=\(volume)")
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

    func recordTranscriptionStats(text: String, duration: TimeInterval) {
        let today = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
        if statsDate != today {
            statsDate = today
            statsTodayCount = 0
            statsTodayChars = 0
            statsTodayDuration = 0
        }
        statsTodayCount += 1
        statsTodayChars += text.count
        statsTodayDuration += duration
        statsTotalCount += 1
        statsTotalChars += text.count
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

    private var lastAccessibilityPromptTime: Date = .distantPast
    private var hasShownAccessibilityPrompt = false

    /// 引导用户修复辅助功能权限。
    /// AXIsProcessTrustedWithOptions(prompt: true) 在权限 stale 时不弹窗（返回 true 但 CGEvent 被丢弃），
    /// 所以直接打开系统设置的辅助功能页面，让用户手动 toggle。
    func openAccessibilitySettings() {
        let now = Date()
        guard now.timeIntervalSince(lastAccessibilityPromptTime) > 60 else {
            viLog("openAccessibilitySettings: suppressed (last prompt was \(String(format: "%.0f", now.timeIntervalSince(lastAccessibilityPromptTime)))s ago)")
            return
        }
        lastAccessibilityPromptTime = now

        // 先尝试系统弹窗（首次安装有效）
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if trusted {
            // 已 "trusted" 但 CGEvent 仍被丢弃 → 权限 stale（重编译后常见）
            // 直接打开系统设置辅助功能页面，让用户 toggle off/on
            viLog("openAccessibilitySettings: AX reports trusted but paste failed — opening System Settings directly")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 启动时检测辅助功能权限是否真正可用。
    ///
    /// `AXIsProcessTrusted()` 检查 TCC 数据库条目，在权限 stale（重编译后）时仍返回 true。
    /// `CGEvent.tapCreate()` 做运行时代码签名验证，更可靠地反映 CGEvent 能否实际发送。
    ///
    /// 三种情况：
    /// 1. AX 未授权 → 弹系统权限对话框（首次安装）
    /// 2. AX "已授权" 但 tapCreate 失败 → 权限 stale → 打开系统设置引导 toggle
    /// 3. AX 已授权且 tapCreate 成功 → 权限正常
    func checkAccessibilityOnLaunch() {
        if !AXIsProcessTrusted() {
            viLog("checkAccessibilityOnLaunch: AX not trusted, requesting permission")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return
        }

        // AXIsProcessTrusted() 返回 true，但可能是 stale。
        // 用 CGEvent.tapCreate 做运行时验证。
        if isCGEventPermissionWorking() {
            viLog("checkAccessibilityOnLaunch: AX trusted + CGEvent tap OK — permissions working")
        } else {
            viLog("checkAccessibilityOnLaunch: AX trusted but CGEvent tap FAILED — permissions stale, opening System Settings")
            openAccessibilitySettings()
        }
    }

    /// 通过创建 CGEvent tap 验证 CGEvent 发送权限是否真正可用。
    /// CGEvent.tapCreate 做运行时代码签名验证，比 AXIsProcessTrusted() 更准确。
    private func isCGEventPermissionWorking() -> Bool {
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )
        if let tap = tap {
            CFMachPortInvalidate(tap)
            return true
        }
        return false
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

    private func resolvedRecordingDeviceUID(_ deviceUID: String?) -> String? {
        guard let deviceUID, !deviceUID.isEmpty, deviceUID != "default" else {
            return AudioDevice.defaultInputDeviceUID()
        }
        return deviceUID
    }

    private var hasRecordingSessionInFlight: Bool {
        recordingSessionPhase != .idle
    }

    private func isCurrentRecordingSession(_ sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        return activeRecordingSessionID == sessionID && hasRecordingSessionInFlight
    }

    private func beginRecordingSessionState() {
        let sessionID = UUID()
        let now = Date()
        let defaultUID = AudioDevice.defaultInputDeviceUID()
        activeRecordingSessionID = sessionID
        recordingSessionPhase = .hotkeyPressed
        hotkeyPressedAt = now
        captureEngineStartedAt = nil
        recordingStartTime = nil
        isRecording = false
        audioRecorder.prepareForRecordingSession(
            hotkeyDownAt: now,
            selectedDeviceUID: selectedMicrophoneID,
            defaultDeviceUID: defaultUID
        )
        viLog(
            "Recording session phase=hotkeyPressed: selectedUID=\(selectedMicrophoneID), " +
            "resolvedUID=\(resolvedRecordingDeviceUID(selectedMicrophoneID) ?? "nil"), " +
            "defaultUID=\(defaultUID ?? "nil"), asrMode=\(asrMode.rawValue)"
        )
    }

    private func markCaptureEngineStarted(for sessionID: UUID) {
        guard isCurrentRecordingSession(sessionID) else {
            viLog("Recording session engineStarted ignored for stale session")
            return
        }
        let now = Date()
        captureEngineStartedAt = now
        if recordingSessionPhase == .audioReady {
            let hotkeyToEngineMs = hotkeyPressedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
            viLog("Recording session engineStarted observed after audioReady: hotkeyToEngineMs=\(hotkeyToEngineMs)")
            isRecording = true
            return
        }
        recordingSessionPhase = .engineStarted
        isRecording = true
        let hotkeyToEngineMs = hotkeyPressedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        viLog("Recording session phase=engineStarted: hotkeyToEngineMs=\(hotkeyToEngineMs)")
    }

    private func markRecordingReady(for sessionID: UUID) {
        guard isCurrentRecordingSession(sessionID) else {
            viLog("Recording session audioReady ignored for stale session")
            return
        }
        recordingSessionPhase = .audioReady
        recordingStartTime = Date()
        isRecording = true
        let hotkeyToReadyMs = hotkeyPressedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        let engineToReadyMs = captureEngineStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        viLog(
            "Recording session phase=audioReady: hotkeyToReadyMs=\(hotkeyToReadyMs), " +
            "engineToReadyMs=\(engineToReadyMs)"
        )
    }

    private func resetRecordingSessionState(reason: String) {
        if hasRecordingSessionInFlight {
            let hotkeyMs = hotkeyPressedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            let engineMs = captureEngineStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            let readyMs = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            viLog(
                "Recording session reset: reason=\(reason), phase=\(recordingSessionPhase.rawValue), " +
                "sinceHotkeyMs=\(hotkeyMs), sinceEngineMs=\(engineMs), sinceReadyMs=\(readyMs)"
            )
        }
        activeRecordingSessionID = nil
        recordingSessionPhase = .idle
        hotkeyPressedAt = nil
        captureEngineStartedAt = nil
        recordingStartTime = nil
        isRecording = false
    }

    private func elapsedSinceReady() -> TimeInterval? {
        guard let recordingStartTime else { return nil }
        return Date().timeIntervalSince(recordingStartTime)
    }

    private func elapsedSinceHotkeyMs() -> Int {
        hotkeyPressedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
    }

    private func subscribeAudioLevelUpdates() {
        audioLevelCancellable?.cancel()
        audioLevelCancellable = audioRecorder.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.overlayManager.updateAudioLevel(level)
            }
    }

    private func showMicError(deviceUID: String?, error: Error) {
        let resolvedDeviceUID = resolvedRecordingDeviceUID(deviceUID)
        let deviceName = resolvedDeviceUID.flatMap { AudioDevice.deviceName(forUID: $0) } ?? "未知设备"

        // 检测 kAUStartIO 失败（error 2003329396）—— 通常是麦克风权限被撤销
        // 常见于 rebuild 后代码签名变更，macOS TCC 将权限标记为 stale
        let nsError = error as NSError
        let isPermissionError = nsError.domain == "com.apple.coreaudio.avfaudio" && nsError.code == 2003329396

        let message: String
        let suggestion: String
        if isPermissionError {
            message = "麦克风权限需要重新授权"
            suggestion = "应用更新后 macOS 需要重新授权麦克风。请前往 系统设置 → 隐私与安全性 → 麦克风，关闭再打开 SpeakLow 的开关"
            viLog("Recording start failed: 麦克风权限错误（kAUStartIO 2003329396），可能是代码签名变更导致权限 stale")
        } else {
            message = "麦克风启动失败（\(deviceName)）"
            let isBluetooth = resolvedDeviceUID.map { AudioDevice.isBluetoothDevice(uid: $0) } ?? false
            suggestion = isBluetooth
                ? "蓝牙设备连接异常，请断开重连或切换到内置麦克风"
                : "请检查麦克风设备，必要时在系统设置中切换输入设备"
            viLog("Recording start failed: \(message) - \(error)")
        }

        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        engineInitTimer?.cancel()
        engineInitTimer = nil
        // 清理流式录音状态，防止 WebSocket 连接泄漏
        if isStreaming {
            viLog("showMicError: cleaning up orphan streaming session")
            streamingService?.disconnect()
            streamingService = nil
            audioRecorder.onStreamingAudioChunk = nil
            isStreaming = false
        }
        resetRecordingSessionState(reason: "mic_error")
        errorMessage = message
        statusText = "Error"
        overlayManager.showError(title: message, suggestion: suggestion)
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
        viLog("handleHotkeyDown() fired, phase=\(recordingSessionPhase.rawValue), isRecording=\(isRecording), isTranscribing=\(isTranscribing)")
        guard !hasRecordingSessionInFlight && !isTranscribing else { return }
        startRecording()
    }

    private func handleHotkeyUp() {
        viLog("handleHotkeyUp() fired, phase=\(recordingSessionPhase.rawValue), isRecording=\(isRecording), isStreaming=\(isStreaming), asrMode=\(asrMode.rawValue)")
        guard hasRecordingSessionInFlight else { return }

        if strategy.needsBridge && isStreaming {
            // FIXME: StreamingStrategy 仍是过渡实现，实际停止逻辑继续走 AppState 现有流程
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.strategy.finish(recorder: self.audioRecorder, overlay: self.overlayManager)
            }
            stopStreamingRecording()
            return
        }

        if strategy.needsBridge {
            // 流式回退到 batch 转写时，改用 BatchStrategy
            stopAndTranscribeBatch(using: BatchStrategy())
        } else {
            stopAndTranscribeBatch()
        }
    }

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        if hasRecordingSessionInFlight {
            switch asrMode {
            case .batch:
                stopAndTranscribeBatch()
            case .streaming:
                stopStreamingRecording()
            }
        } else {
            startRecording()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        // Prevent double-entry: hotkey can fire twice before isRecording is set
        guard !hasRecordingSessionInFlight else { return }

        // API Key 未配置时拦截录音，引导用户去设置（节流：3 秒内不重复弹窗）
        if EnvLoader.loadDashScopeAPIKey() == nil || EnvLoader.loadDashScopeAPIKey()!.isEmpty {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastAPIKeyAlertTime < 3.0 { return }
            lastAPIKeyAlertTime = now
            viLog("录音拦截：API Key 未配置")
            overlayManager.showError(title: "API Key 未配置", suggestion: "请在设置 → 密钥中配置")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard self != nil else { return }
                NotificationCenter.default.post(name: .showSettingsAPIKey, object: nil)
            }
            return
        }

        beginRecordingSessionState()

        let t0 = CFAbsoluteTimeGetCurrent()
        viLog("startRecording() entered")
        // 清理上一次的残留 UI（text result panel、error overlay 等）
        overlayManager.dismiss()
        // Cancel any leftover safety timeout from a previous session
        safetyTimeoutWork?.cancel()
        safetyTimeoutWork = nil
        // Update AX status for UI, but don't block recording or prompt.
        // AX only affects text insertion method; TextInserter has clipboard fallback.
        // (see commit 9189221: AXIsProcessTrusted() flickers after recompile)
        hasAccessibility = AXIsProcessTrusted()
        viLog("AXIsProcessTrusted() = \(hasAccessibility)")
        guard ensureMicrophoneAccess() else {
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
                        self?.resetRecordingSessionState(reason: "microphone_access_denied")
                        self?.errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
                        self?.statusText = "No Microphone"
                        self?.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            resetRecordingSessionState(reason: "microphone_access_denied")
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            showMicrophonePermissionAlert()
            return false
        }
    }

    private func beginRecording() {
        os_log(.info, log: recordingLog, "beginRecording() entered, asrMode=\(self.asrMode.rawValue)")
        errorMessage = nil
        statusText = "Starting..."
        let sessionID = activeRecordingSessionID

        Task { [weak self] in
            guard let self else { return }
            let prepared = await self.strategy.prepare(bridgeManager: self.bridgeManager)
            await MainActor.run {
                guard self.isCurrentRecordingSession(sessionID) else { return }
                guard prepared else {
                    viLog("beginRecording: strategy prepare failed")
                    self.resetRecordingSessionState(reason: "strategy_prepare_failed")
                    self.statusText = "语音功能异常"
                    self.errorMessage = "语音功能出了问题"
                    self.playSound("Basso", volume: self.soundVolumeError)
                    self.overlayManager.showError(
                        title: "语音功能出了问题",
                        suggestion: "请退出并重新打开 SpeakLow"
                    )
                    return
                }

                self.strategy.begin(recorder: self.audioRecorder, overlay: self.overlayManager)

                if self.strategy.needsBridge {
                    // FIXME: 流式路径仍由 AppState 现有实现驱动，Strategy 仅做过渡接入
                    self._beginRecordingStreaming()
                } else {
                    self._beginRecordingBatch()
                }
            }
        }
    }

    /// Batch 模式：直接开始录音，无需 bridge
    private func _beginRecordingBatch() {
        viLog("Batch mode: starting recording (no bridge needed)")
        let sessionID = activeRecordingSessionID

        // Show initializing dots only if engine takes longer than 0.5s
        var overlayShown = false
        engineInitTimer?.cancel()
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        initTimer.schedule(deadline: .now() + 0.5)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            overlayShown = true
            self.overlayManager.showInitializing()
        }
        initTimer.resume()
        engineInitTimer = initTimer

        let deviceUID = resolvedRecordingDeviceUID(selectedMicrophoneID)
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isCurrentRecordingSession(sessionID) else { return }
                initTimer.cancel()
                if let sessionID {
                    self.markRecordingReady(for: sessionID)
                }
                self.statusText = "Recording..."
                if overlayShown {
                    self.overlayManager.transitionToRecording()
                } else {
                    self.overlayManager.showRecording()
                }
                self.overlayManager.updatePreviewText("🎙 正在录音...")
                overlayShown = true
                self.playSound("Tink", volume: self.soundVolumeStart)
            }
        }

        audioRecorder.onSilenceTimeout = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isCurrentRecordingSession(sessionID) else { return }
                initTimer.cancel()
                self.audioLevelCancellable?.cancel()
                self.audioLevelCancellable = nil
                self.resetRecordingSessionState(reason: "batch_silence_timeout")
                self.statusText = "麦克风没有声音"
                self.errorMessage = "麦克风没有声音"
                self.playSound("Basso", volume: self.soundVolumeError)
                self.overlayManager.showError(
                    title: "麦克风没有声音",
                    suggestion: "请检查麦克风是否正常连接"
                )
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.audioRecorder.startRecording(deviceUID: deviceUID)
                DispatchQueue.main.async {
                    guard self.isCurrentRecordingSession(sessionID) else {
                        viLog("Batch mode: engine started after session ended, ignoring")
                        return
                    }
                    if let sessionID {
                        self.markCaptureEngineStarted(for: sessionID)
                    }
                    self.subscribeAudioLevelUpdates()
                }
            } catch {
                viLog("Batch recording start failed on first attempt: \(error.localizedDescription)")
                self.audioRecorder.invalidateEngine()
                do {
                    try self.audioRecorder.startRecording(deviceUID: deviceUID)
                    DispatchQueue.main.async {
                        guard self.isCurrentRecordingSession(sessionID) else {
                            viLog("Batch mode: retry engine started after session ended, ignoring")
                            return
                        }
                        if let sessionID {
                            self.markCaptureEngineStarted(for: sessionID)
                        }
                        self.subscribeAudioLevelUpdates()
                    }
                } catch {
                    viLog("Batch recording start failed after engine reset: \(error.localizedDescription)")
                    let builtInUID = AudioDevice.builtInMicrophoneUID()
                    if let builtInUID, deviceUID != builtInUID {
                        self.audioRecorder.invalidateEngine()
                        do {
                            try self.audioRecorder.startRecording(deviceUID: builtInUID)
                            DispatchQueue.main.async {
                                guard self.isCurrentRecordingSession(sessionID) else {
                                    viLog("Batch mode: built-in fallback started after session ended, ignoring")
                                    return
                                }
                                if let sessionID {
                                    self.markCaptureEngineStarted(for: sessionID)
                                }
                                self.subscribeAudioLevelUpdates()
                                self.overlayManager.showError(
                                    title: "已切换到内置麦克风",
                                    suggestion: "原设备连接异常，已自动切换"
                                )
                            }
                        } catch {
                            DispatchQueue.main.async {
                                initTimer.cancel()
                                self.showMicError(deviceUID: deviceUID, error: error)
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            initTimer.cancel()
                            self.showMicError(deviceUID: deviceUID, error: error)
                        }
                    }
                }
            }
        }
    }

    /// Streaming 模式：先检查 bridge 再开始录音
    private func _beginRecordingStreaming() {
        // Pre-flight: check if asr-bridge is reachable; auto-restart if not
        let healthService = TranscriptionService()
        let sessionID = activeRecordingSessionID
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
                    self.resetRecordingSessionState(reason: "streaming_bridge_unhealthy")
                    self.statusText = "语音功能异常"
                    self.errorMessage = "语音功能出了问题"
                    self.playSound("Basso", volume: self.soundVolumeError)
                    self.overlayManager.showError(
                        title: "语音功能出了问题",
                        suggestion: "请退出并重新打开 SpeakLow"
                    )
                }
                return
            }
            await MainActor.run {
                guard self.isCurrentRecordingSession(sessionID) else {
                    viLog("Pre-flight: user released key during health check, aborting")
                    return
                }
                self._beginRecordingAfterHealthCheck()
            }
        }
    }

    private func _beginRecordingAfterHealthCheck() {
        let sessionID = activeRecordingSessionID
        // Show initializing dots only if engine takes longer than 0.5s to start
        var overlayShown = false
        engineInitTimer?.cancel()
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        initTimer.schedule(deadline: .now() + 0.5)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.overlayManager.showInitializing()
        }
        initTimer.resume()
        engineInitTimer = initTimer

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

        let deviceUID = resolvedRecordingDeviceUID(selectedMicrophoneID)
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isCurrentRecordingSession(sessionID) else { return }
                initTimer.cancel()
                os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                if let sessionID {
                    self.markRecordingReady(for: sessionID)
                }
                self.statusText = "Recording..."
                if overlayShown {
                    self.overlayManager.transitionToRecording()
                } else {
                    self.overlayManager.showRecording()
                }
                overlayShown = true
                self.playSound("Tink", volume: self.soundVolumeStart)
            }
        }

        audioRecorder.onSilenceTimeout = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isCurrentRecordingSession(sessionID) else { return }
                viLog("Silence timeout — stopping recording and showing error")
                initTimer.cancel()
                self.audioLevelCancellable?.cancel()
                self.audioLevelCancellable = nil
                // 清理流式状态，防止 WebSocket 泄漏
                if self.isStreaming {
                    viLog("Silence timeout: cleaning up streaming session")
                    self.streamingService?.disconnect()
                    self.streamingService = nil
                    self.audioRecorder.onStreamingAudioChunk = nil
                    self.isStreaming = false
                }
                _ = self.audioRecorder.stopRecording()
                self.resetRecordingSessionState(reason: "streaming_silence_timeout")

                // 蓝牙麦克风静默时，自动提示切换到内置麦克风
                let defaultUID = AudioDevice.defaultInputDeviceUID()
                let isBluetooth = defaultUID.map { AudioDevice.isBluetoothDevice(uid: $0) } ?? false
                let suggestion = isBluetooth
                    ? "蓝牙麦克风无声音输入，请尝试在设置中切换到内置麦克风"
                    : "请检查麦克风是否正常连接"
                if isBluetooth {
                    viLog("Silence timeout: 当前为蓝牙设备(\(defaultUID ?? "unknown"))，建议切换到内置麦克风")
                }

                self.statusText = "麦克风没有声音"
                self.errorMessage = "麦克风没有声音"
                self.playSound("Basso", volume: self.soundVolumeError)
                self.overlayManager.showError(
                    title: "麦克风没有声音",
                    suggestion: suggestion
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
                    guard self.isCurrentRecordingSession(sessionID) else {
                        viLog("Streaming mode: engine started after session ended, ignoring")
                        return
                    }
                    if let sessionID {
                        self.markCaptureEngineStarted(for: sessionID)
                    }
                    self.subscribeAudioLevelUpdates()
                }
            } catch {
                viLog("Streaming recording start failed on first attempt: \(error.localizedDescription)")
                self.audioRecorder.invalidateEngine()
                // 等待 200ms 让旧 engine 完全释放（invalidateEngine 内部有 100ms deferred release）
                Thread.sleep(forTimeInterval: 0.2)
                do {
                    try self.audioRecorder.startRecording(deviceUID: deviceUID)
                    DispatchQueue.main.async {
                        guard self.isCurrentRecordingSession(sessionID) else {
                            viLog("Streaming mode: retry engine started after session ended, ignoring")
                            return
                        }
                        if let sessionID {
                            self.markCaptureEngineStarted(for: sessionID)
                        }
                        self.subscribeAudioLevelUpdates()
                    }
                } catch {
                    viLog("Streaming recording start failed after engine reset: \(error.localizedDescription)")
                    let builtInUID = AudioDevice.builtInMicrophoneUID()
                    if let builtInUID, deviceUID != builtInUID {
                        self.audioRecorder.invalidateEngine()
                        Thread.sleep(forTimeInterval: 0.2)
                        do {
                            try self.audioRecorder.startRecording(deviceUID: builtInUID)
                            DispatchQueue.main.async {
                                guard self.isCurrentRecordingSession(sessionID) else {
                                    viLog("Streaming mode: built-in fallback started after session ended, ignoring")
                                    return
                                }
                                if let sessionID {
                                    self.markCaptureEngineStarted(for: sessionID)
                                }
                                self.subscribeAudioLevelUpdates()
                                self.overlayManager.showError(
                                    title: "已切换到内置麦克风",
                                    suggestion: "原设备连接异常，已自动切换"
                                )
                            }
                        } catch {
                            DispatchQueue.main.async {
                                initTimer.cancel()
                                self.showMicError(deviceUID: deviceUID, error: error)
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            initTimer.cancel()
                            self.showMicError(deviceUID: deviceUID, error: error)
                        }
                    }
                }
            }
        }
    }


    // MARK: - Batch Mode Stop & Transcribe

    private func stopAndTranscribeBatch(using finishStrategy: TranscriptionStrategy? = nil) {
        let strategyToUse = finishStrategy ?? strategy
        viLog("stopAndTranscribeBatch() entered, strategy=\(String(describing: type(of: strategyToUse)))")
        engineInitTimer?.cancel()
        engineInitTimer = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        guard recordingSessionPhase == .audioReady, let elapsed = elapsedSinceReady() else {
            viLog(
                "Batch: recording stopped before audioReady, phase=\(recordingSessionPhase.rawValue), " +
                "sinceHotkeyMs=\(elapsedSinceHotkeyMs())"
            )
            _ = audioRecorder.stopRecording()
            resetRecordingSessionState(reason: "batch_stop_before_ready")
            overlayManager.dismiss()
            return
        }
        if elapsed < 0.2 {
            viLog("Batch: 录音时长 \(Int(elapsed * 1000))ms < 200ms，丢弃")
            _ = audioRecorder.stopRecording()
            resetRecordingSessionState(reason: "batch_too_short")
            overlayManager.dismiss()
            return
        }
        resetRecordingSessionState(reason: "batch_stop_transcribe")

        isTranscribing = true
        statusText = "识别中..."
        self.playSound("Pop", volume: self.soundVolumeStop)
        overlayManager.showTranscribing()
        overlayManager.updatePreviewText("🔍 正在识别...")

        Task {
            do {
                let rawTranscript = try await strategyToUse.finish(recorder: self.audioRecorder, overlay: self.overlayManager)
                let trimmed = (rawTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                viLog("Batch: transcription result='\(trimmed.prefix(40))' (length=\(trimmed.count))")

                if trimmed.isEmpty {
                    await MainActor.run {
                        self.isTranscribing = false
                        self.statusText = "未检测到语音"
                        self.playSound("Basso", volume: self.soundVolumeError)
                        self.overlayManager.showError(
                            title: "未检测到语音",
                            suggestion: "请靠近麦克风说话"
                        )
                    }
                    return
                }

                await MainActor.run {
                    self.isTranscribing = false
                    self.lastTranscript = trimmed

                    if self.llmRefineEnabled {
                        self.overlayManager.updatePreviewText("✨ 正在优化...")
                        viLog("Batch: starting DashScope refine, style=\(self.refineStyle.rawValue)")
                        let style = self.refineStyle
                        Task {
                            let refined = await DashScopeClient.shared.refine(text: trimmed, style: style)
                            await MainActor.run {
                                self.batchInsertAndFinish(originalText: trimmed, finalText: refined)
                            }
                        }
                    } else {
                        self.batchInsertAndFinish(originalText: trimmed, finalText: trimmed)
                    }
                }
            } catch {
                viLog("Batch: transcription FAILED: \(error.localizedDescription)")
                let (errTitle, errSuggestion) = self.userFriendlyTranscriptionError(error)
                await MainActor.run {
                    self.isTranscribing = false
                    self.errorMessage = error.localizedDescription
                    self.statusText = errTitle
                    self.playSound("Basso", volume: self.soundVolumeError)
                    self.overlayManager.showError(title: errTitle, suggestion: errSuggestion)
                }
            }

            // 5秒后重置状态栏
            await MainActor.run {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if self.statusText.hasPrefix("已插入") || self.statusText.hasPrefix("已粘贴") ||
                       self.statusText.hasPrefix("已复制") || self.statusText.hasPrefix("识别失败") ||
                       self.statusText == "未检测到语音" {
                        self.statusText = "Ready"
                    }
                }
            }
        }
    }

    // MARK: - Streaming Recording

    private func stopStreamingRecording() {
        viLog("stopStreamingRecording() entered")
        engineInitTimer?.cancel()
        engineInitTimer = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        guard recordingSessionPhase == .audioReady, let elapsed = elapsedSinceReady() else {
            viLog(
                "stopStreamingRecording: stopped before audioReady, phase=\(recordingSessionPhase.rawValue), " +
                "sinceHotkeyMs=\(elapsedSinceHotkeyMs())"
            )
            audioRecorder.onStreamingAudioChunk = nil
            _ = audioRecorder.stopRecording()
            recordingDuration = 0
            wavFileURL = nil
            resetRecordingSessionState(reason: "streaming_stop_before_ready")
            safetyTimeoutWork?.cancel()
            safetyTimeoutWork = nil
            streamingHasFinished = true
            streamingService?.disconnect()
            streamingService = nil
            isStreaming = false
            overlayManager.dismiss()
            return
        }
        if elapsed < 0.2 {
            viLog("stopStreamingRecording: 录音时长 \(Int(elapsed * 1000))ms < 200ms，丢弃")
            audioRecorder.onStreamingAudioChunk = nil
            _ = audioRecorder.stopRecording()
            recordingDuration = 0
            wavFileURL = nil
            resetRecordingSessionState(reason: "streaming_too_short")
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

        // Stop recording (flushes remaining audio buffer)
        wavFileURL = audioRecorder.stopRecording()
        resetRecordingSessionState(reason: "streaming_stop_finalize")

        // Tell streaming service we're done sending audio
        streamingService?.stop()
        viLog("stopStreamingRecording: stop message sent to bridge")

        // Show finalizing indicator immediately
        overlayManager.showTranscribing()
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

    /// Routes an error to user-facing (title, suggestion) preferring the structured
    /// bridge code (see asr-bridge/stream.go classifyBridgeErr / classifyDashEventError).
    /// Falls back to legacy substring matching when no code is present (older bridge).
    private func userFriendlyError(_ error: Error) -> (title: String, suggestion: String) {
        if let streamErr = error as? StreamingError, let code = streamErr.bridgeCode {
            switch code {
            case "network_dns":
                return ("没有网络连接", "请检查 Wi-Fi 或网络设置")
            case "network_refused", "network_broken":
                return ("网络连接断了", "请检查网络连接后再试")
            case "upstream_timeout", "upstream_handshake":
                return ("网络太慢了", "请检查网络连接后再试")
            case "upstream_connect":
                return ("无法连接识别服务", "请检查网络连接后再试")
            case "upstream_server":
                return ("识别服务出了点问题", "通常很快恢复，请稍后再试")
            case "auth_invalid":
                return ("语音识别密钥（API Key）无效", "请检查 ~/.config/speaklow/.env 中的配置")
            case "auth_forbidden":
                return ("语音识别密钥（API Key）认证失败", "请联系应用提供者或检查配置")
            case "auth_quota":
                return ("语音识别密钥（API Key）余额不足", "请联系应用提供者，或自行在 ~/.config/speaklow/.env 中更换")
            case "rate_limit":
                return ("请求太频繁了", "请稍等一会儿再试")
            case "asr_empty_audio":
                return ("识别服务没收到音频", "请重试（网络慢时可能丢失前段语音）")
            case "asr_no_speech":
                return ("未检测到语音", "请靠近麦克风说话")
            case "asr_upstream_error":
                return ("识别服务出了点问题", "请重试")
            case "client_protocol", "bridge_internal":
                return ("语音功能出了问题", "请退出并重新打开 SpeakLow")
            default:
                break // fall through to legacy
            }
        }
        return userFriendlyTranscriptionError(error)
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

        // 4. API auth / quota / billing errors
        if desc.contains("arrearage") || desc.contains("account is in good standing") ||
           desc.contains("overdue") {
            return ("语音识别密钥（API Key）余额不足", "请联系应用提供者，或自行在 ~/.config/speaklow/.env 中更换")
        }
        if desc.contains("invalid api") || desc.contains("invalid_api_key") ||
           desc.contains("api key") {
            return ("语音识别密钥（API Key）无效", "请检查 ~/.config/speaklow/.env 中的配置")
        }
        if desc.contains("401") || desc.contains("403") ||
           desc.contains("unauthorized") || desc.contains("authentication") ||
           desc.contains("access denied") {
            return ("语音识别密钥（API Key）认证失败", "请联系应用提供者或检查配置")
        }
        if desc.contains("429") || desc.contains("rate limit") || desc.contains("quota") ||
           desc.contains("too many requests") {
            return ("请求太频繁了", "请稍等一会儿再试")
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
        lastPartialText = ""
    }
    func streamingDidReceivePartial(text: String) {
        // 拦截 corpus leak：DashScope 在静默时会把 session config 中的热词提示文本回传
        if isCorpusLeak(text) { return }
        // 节流日志：只在文本实际变化时记录，避免每秒数条重复日志
        if text != lastPartialText {
            viLog("Streaming partial: \(text.prefix(80))")
        }
        let display = committedSentences.joined() + text
        overlayManager.updatePreviewText(display)
        lastPartialText = text
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
            let refined = await DashScopeClient.shared.refine(text: text, style: style)
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
            // Disambiguate "user was silent" vs "ASR got no response" using whether
            // the microphone captured any non-silent audio during this session.
            // Before this fix, both paths showed "未检测到语音" — misleading when a
            // network/upstream issue silently dropped all partials (Case A).
            let title: String
            let suggestion: String
            if audioRecorder.hasCapturedAudio {
                title = "识别服务没有响应"
                suggestion = "请重试。如反复出现，请检查网络连接"
                viLog("Streaming: empty result despite captured audio — likely upstream/network issue")
            } else {
                title = "未检测到语音"
                suggestion = "请靠近麦克风说话"
            }
            statusText = title
            self.playSound("Basso", volume: self.soundVolumeError)
            overlayManager.dismissPreviewPanel()
            overlayManager.showError(title: title, suggestion: suggestion)
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
            // 优先复用 pre-refine 缓存（流式模式下 streamingDidReceiveSentence 已预发起）
            if usePreRefined {
                // 所有 pre-refine 已完成，直接用缓存
                if pendingRefineCount == 0 && !sentenceRefineCache.isEmpty {
                    let refined = committedSentences.map { sentenceRefineCache[$0] ?? $0 }.joined()
                    if !refined.isEmpty {
                        viLog("applyFinalTranscript: using pre-refined sentences (all cached)")
                        insertAndFinish(originalText: text, finalText: refined)
                        return
                    }
                }
                // 有正在进行的 pre-refine，等待完成后复用缓存，避免重复 refine
                if pendingRefineCount > 0 {
                    viLog("applyFinalTranscript: waiting for \(pendingRefineCount) pending pre-refine(s)")
                    overlayManager.updatePreviewText("✨ 正在优化...")
                    let committed = committedSentences
                    Task {
                        // 最多等 3 秒
                        for _ in 0..<30 {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            let ready = await MainActor.run { self.pendingRefineCount == 0 }
                            if ready { break }
                        }
                        await MainActor.run {
                            let refined = committed.map { self.sentenceRefineCache[$0] ?? $0 }.joined()
                            if !refined.isEmpty {
                                viLog("applyFinalTranscript: pre-refine completed, using cached result")
                                self.insertAndFinish(originalText: text, finalText: refined)
                            } else {
                                self.insertAndFinish(originalText: text, finalText: text)
                            }
                        }
                    }
                    return
                }
            }

            overlayManager.updatePreviewText("✨ 正在优化...")
            viLog("applyFinalTranscript: starting LLM refine, style=\(refineStyle.rawValue)")
            let style = refineStyle
            Task {
                let refined = await DashScopeClient.shared.refine(text: text, style: style)
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
            self.playSound("Purr", volume: self.soundVolumeFallback)
            overlayManager.showTextResult(finalText)
            openAccessibilitySettings()
        } else {
            self.playSound("Glass", volume: self.soundVolumeSuccess)
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

        overlayManager.dismissPreviewPanel()

        viLog("Batch: inserting text, length=\(finalText.count)")
        let insertResult = TextInserter.insert(finalText)
        viLog("Batch: insert result=\(insertResult)")

        switch insertResult {
        case .insertedViaAX:
            statusText = "已插入: \(finalText.prefix(20))..."

            self.playSound("Glass", volume: self.soundVolumeSuccess)
            overlayManager.showDone()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.overlayManager.dismiss()
            }
        case .pastedViaClipboard:
            statusText = "已粘贴: \(finalText.prefix(20))..."

            self.playSound("Glass", volume: self.soundVolumeSuccess)
            overlayManager.showDone()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.overlayManager.dismiss()
            }
        case .copiedToClipboard:
            statusText = "已复制到剪贴板（请手动粘贴）"
            self.playSound("Purr", volume: self.soundVolumeFallback)
            overlayManager.showTextResult(finalText)
            openAccessibilitySettings()
        }
    }

    func streamingDidFail(error: Error) {
        guard !streamingHasFinished else {
            viLog("Streaming: close callback after finish, ignoring")
            return
        }
        // 防止已清理的旧 WS 回调影响当前 session
        // showMicError/silenceTimeout 已设 isStreaming=false，此处不应再处理
        guard isStreaming else {
            viLog("Streaming: fail callback but isStreaming=false (stale WS), ignoring")
            return
        }

        viLog("Streaming FAILED: \(error.localizedDescription) [code=\((error as? StreamingError)?.bridgeCode ?? "none")]")

        isStreaming = false
        streamingService?.disconnect()
        streamingService = nil
        audioRecorder.onStreamingAudioChunk = nil
        overlayManager.dismissPreviewPanel()

        // Classify: unrecoverable means batch fallback would also fail (network / auth).
        // Prefer structured bridge code; fall back to substring matching for older bridge.
        let bridgeCode = (error as? StreamingError)?.bridgeCode ?? ""
        let isUnrecoverable: Bool
        switch bridgeCode {
        case "network_dns", "network_refused", "network_broken",
             "auth_invalid", "auth_forbidden", "auth_quota",
             "upstream_connect":
            isUnrecoverable = true
        case "asr_empty_audio", "asr_upstream_error", "upstream_timeout",
             "upstream_handshake", "upstream_server", "rate_limit",
             "asr_no_speech", "bridge_internal", "client_protocol":
            isUnrecoverable = false
        default:
            // No code or unknown — legacy substring match
            let desc = error.localizedDescription.lowercased()
            let isNetworkError = desc.contains("no such host") || desc.contains("dns") ||
                desc.contains("not connected to the internet") || desc.contains("network is unreachable")
            let isAuthError = desc.contains("401") || desc.contains("403") || desc.contains("unauthorized") ||
                desc.contains("arrearage") || desc.contains("access denied") || desc.contains("account is in good standing") ||
                desc.contains("invalid api") || desc.contains("invalid_api_key")
            isUnrecoverable = isNetworkError || isAuthError
        }

        // Show error whenever:
        //   (a) error is unrecoverable (batch fallback would also fail), OR
        //   (b) user already released the hotkey (no batch fallback path remains)
        // Previously (b) dismissed silently, leaving user with no feedback when bridge
        // returned an error after hotkey release (e.g. asr_empty_audio on slow handshake).
        if isUnrecoverable || !isRecording {
            let reason = isUnrecoverable ? "unrecoverable" : "post-release"
            viLog("Streaming: \(reason) error, showing user feedback")
            _ = audioRecorder.stopRecording()
            resetRecordingSessionState(reason: "streaming_failed_\(reason)")
            let (errTitle, errSuggestion) = userFriendlyError(error)
            statusText = errTitle
            errorMessage = error.localizedDescription
            self.playSound("Basso", volume: self.soundVolumeError)
            overlayManager.showError(title: errTitle, suggestion: errSuggestion)
            return
        }

        // Recoverable: keep recording for batch fallback.
        // When user releases hotkey, handleHotkeyUp will call stopAndTranscribeBatch().
    }
}
