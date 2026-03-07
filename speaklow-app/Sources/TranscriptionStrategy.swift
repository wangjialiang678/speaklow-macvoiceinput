import Foundation

// MARK: - ASR Mode

/// ASR 模式
enum ASRMode: String, CaseIterable, Identifiable {
    case batch = "batch"
    case streaming = "streaming"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .batch: return "无预览"
        case .streaming: return "实时预览"
        }
    }
}

// MARK: - TranscriptionStrategy Protocol

/// 转写策略协议
protocol TranscriptionStrategy {
    /// 是否需要 Bridge 进程
    var needsBridge: Bool { get }
    /// 录音前准备（如 Bridge 健康检查），返回 false 表示不可用
    func prepare(bridgeManager: ASRBridgeManager?) async -> Bool
    /// 开始录音，设置必要的回调
    func begin(recorder: AudioRecorder, overlay: RecordingOverlayManager)
    /// 停止录音并返回转写文本（异步）
    func finish(recorder: AudioRecorder, overlay: RecordingOverlayManager) async throws -> String?
}

// MARK: - BatchStrategy

/// Batch 模式：录完后一次性调用 DashScope REST API 识别
final class BatchStrategy: TranscriptionStrategy {
    let needsBridge = false
    private let client = DashScopeClient.shared

    func prepare(bridgeManager: ASRBridgeManager?) async -> Bool {
        // Batch 模式不需要 Bridge，直接返回 true
        return true
    }

    func begin(recorder: AudioRecorder, overlay: RecordingOverlayManager) {
        // Batch 模式只显示波形，不显示文字预览
        // 录音由 AppState 控制启动，这里不需要额外操作
        viLog("BatchStrategy: begin recording")
    }

    func finish(recorder: AudioRecorder, overlay: RecordingOverlayManager) async throws -> String? {
        viLog("BatchStrategy: finish, getting audio file")

        // 在主线程停止录音，避免 AVAudioEngine 相关对象被跨线程访问
        guard let fileURL = await MainActor.run(body: { recorder.stopRecording() }) else {
            viLog("BatchStrategy: no audio file")
            return nil
        }

        viLog("BatchStrategy: transcribing \(fileURL.lastPathComponent)")

        let text = try await client.transcribe(audioFileURL: fileURL)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if isCorpusLeak(trimmed) {
            viLog("BatchStrategy: corpus leak detected, returning nil")
            return nil
        }

        if trimmed.isEmpty {
            viLog("BatchStrategy: empty transcription")
            return nil
        }

        viLog("BatchStrategy: got '\(trimmed.prefix(40))' (\(trimmed.count) chars)")
        return trimmed
    }
}

// MARK: - StreamingStrategy

/// Streaming 模式：通过 Bridge WebSocket 实时流式转写
final class StreamingStrategy: TranscriptionStrategy {
    let needsBridge = true

    func prepare(bridgeManager: ASRBridgeManager?) async -> Bool {
        guard let bridge = bridgeManager else {
            viLog("StreamingStrategy: no bridge manager")
            return false
        }
        return await bridge.ensureRunning()
    }

    func begin(recorder: AudioRecorder, overlay: RecordingOverlayManager) {
        // 流式模式的具体初始化由 AppState 中的现有代码处理
        // 这是一个过渡实现，完整迁移在 Integration 阶段完成
        viLog("StreamingStrategy: begin (delegate to AppState streaming logic)")
    }

    func finish(recorder: AudioRecorder, overlay: RecordingOverlayManager) async throws -> String? {
        // 流式模式的完成逻辑由 AppState 中的现有代码处理
        // 这是一个过渡实现
        viLog("StreamingStrategy: finish (delegate to AppState streaming logic)")
        return nil  // AppState 自行处理流式结果
    }
}
