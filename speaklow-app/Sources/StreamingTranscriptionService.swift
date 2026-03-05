import Foundation
import os

// MARK: - Delegate Protocol

protocol StreamingTranscriptionDelegate: AnyObject {
    /// Bridge is connected and ready to receive audio
    func streamingDidStart()
    /// Partial (in-progress) text for overlay display
    func streamingDidReceivePartial(text: String)
    /// Complete sentence ready to be pasted
    func streamingDidReceiveSentence(text: String)
    /// Streaming session fully complete
    func streamingDidFinish()
    /// Error occurred; caller should fall back to batch mode
    func streamingDidFail(error: Error)
}

// MARK: - Service

class StreamingTranscriptionService {

    weak var delegate: StreamingTranscriptionDelegate?

    private let bridgeURL: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false

    private let logger = Logger(subsystem: "com.speaklow.app", category: "StreamingTranscription")

    init(bridgeURL: String = "ws://localhost:18089") {
        self.bridgeURL = bridgeURL
    }

    // MARK: - Public API

    func start(model: String = "qwen3-asr-flash-realtime", sampleRate: Int = 16000) {
        guard let url = URL(string: "\(bridgeURL)/v1/stream") else {
            delegate?.streamingDidFail(error: StreamingError.invalidURL)
            return
        }

        logger.info("connecting to \(url.absoluteString)")

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        // Send "start" message
        let startMsg: [String: Any] = [
            "type": "start",
            "model": model,
            "sample_rate": sampleRate,
            "format": "pcm"
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: startMsg),
              let text = String(data: data, encoding: .utf8) else {
            delegate?.streamingDidFail(error: StreamingError.encodingFailed)
            return
        }

        webSocketTask?.send(.string(text)) { [weak self] error in
            if let error = error {
                self?.logger.error("send start failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.delegate?.streamingDidFail(error: error)
                }
                return
            }
            self?.receiveMessage()
        }
    }

    func sendAudioChunk(_ pcmData: Data) {
        guard webSocketTask != nil, isConnected else { return }

        let base64 = pcmData.base64EncodedString()
        let msg: [String: Any] = [
            "type": "audio",
            "data": base64
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocketTask?.send(.string(text)) { [weak self] error in
            if let error = error {
                self?.logger.error("send audio failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        logger.info("sending stop message")

        let msg: [String: Any] = ["type": "stop"]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocketTask?.send(.string(text)) { [weak self] error in
            if let error = error {
                self?.logger.error("send stop failed: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        logger.info("disconnecting")
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Private

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleBridgeMessage(text)
                default:
                    break
                }
                // Continue listening (unless finished/error)
                if self.isConnected || !self.isConnected {
                    // Always try to receive next message until we explicitly disconnect
                    self.receiveMessage()
                }

            case .failure(let error):
                self.logger.error("receive failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.delegate?.streamingDidFail(error: error)
                }
            }
        }
    }

    private func handleBridgeMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            logger.warning("invalid bridge message: \(text.prefix(100))")
            return
        }

        switch type {
        case "started":
            logger.info("bridge: started")
            isConnected = true
            DispatchQueue.main.async {
                self.delegate?.streamingDidStart()
            }

        case "partial":
            if let partialText = json["text"] as? String {
                logger.debug("bridge: partial '\(partialText.prefix(30))'")
                DispatchQueue.main.async {
                    self.delegate?.streamingDidReceivePartial(text: partialText)
                }
            }

        case "final":
            if let sentenceText = json["text"] as? String {
                logger.info("bridge: final sentence '\(sentenceText.prefix(30))'")
                DispatchQueue.main.async {
                    self.delegate?.streamingDidReceiveSentence(text: sentenceText)
                }
            }

        case "finished":
            logger.info("bridge: finished")
            isConnected = false
            DispatchQueue.main.async {
                self.delegate?.streamingDidFinish()
            }

        case "error":
            let errorMsg = json["error"] as? String ?? "unknown"
            logger.error("bridge: error \(errorMsg)")
            isConnected = false
            DispatchQueue.main.async {
                self.delegate?.streamingDidFail(error: StreamingError.bridgeError(errorMsg))
            }

        default:
            logger.warning("bridge: unknown type '\(type)'")
        }
    }
}

// MARK: - Errors

enum StreamingError: LocalizedError {
    case invalidURL
    case encodingFailed
    case bridgeError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid bridge WebSocket URL"
        case .encodingFailed: return "Failed to encode message"
        case .bridgeError(let msg): return "Bridge error: \(msg)"
        }
    }
}
