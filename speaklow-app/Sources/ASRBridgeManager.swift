import Foundation
import os.log

private let bridgeLog = OSLog(subsystem: "com.speaklow.app", category: "ASRBridge")

class ASRBridgeManager {
    private var process: Process?

    func start() throws {
        // 1. Find asr-bridge binary
        let bundlePath = Bundle.main.bundlePath
        let primaryPath = bundlePath + "/Contents/MacOS/asr-bridge"
        let devPath = bundlePath + "/../asr-bridge"

        let binaryPath: String
        if FileManager.default.fileExists(atPath: primaryPath) {
            binaryPath = primaryPath
            os_log(.info, log: bridgeLog, "Found asr-bridge at bundle path: %{public}@", primaryPath)
        } else if FileManager.default.fileExists(atPath: devPath) {
            binaryPath = devPath
            os_log(.info, log: bridgeLog, "Found asr-bridge at dev path: %{public}@", devPath)
        } else {
            os_log(.error, log: bridgeLog, "asr-bridge binary NOT FOUND, checked: %{public}@ and %{public}@", primaryPath, devPath)
            return
        }

        // 2. Load environment from .env file
        let env = buildEnvironment()
        let hasAPIKey = env["DASHSCOPE_API_KEY"] != nil && !env["DASHSCOPE_API_KEY"]!.isEmpty
        os_log(.info, log: bridgeLog, "DASHSCOPE_API_KEY present: %{public}d", hasAPIKey)

        // 3. Launch process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.environment = env

        // Capture stdout/stderr for logging
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                os_log(.info, log: bridgeLog, "[asr-bridge] %{public}@", str.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        proc.terminationHandler = { [weak self] process in
            os_log(.info, log: bridgeLog, "asr-bridge terminated with exit code %d", process.terminationStatus)
            DispatchQueue.main.async {
                self?.process = nil
            }
        }

        try proc.run()
        process = proc
        os_log(.info, log: bridgeLog, "Started asr-bridge pid=%d", proc.processIdentifier)

        // 4. Poll /health up to 5 seconds
        Task {
            let service = TranscriptionService()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if await service.checkHealth() {
                    os_log(.info, log: bridgeLog, "asr-bridge is READY")
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            os_log(.error, log: bridgeLog, "asr-bridge health check TIMED OUT after 5s")
        }
    }

    func stop() {
        os_log(.info, log: bridgeLog, "Stopping asr-bridge...")
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        os_log(.info, log: bridgeLog, "asr-bridge stopped")
    }

    var isRunning: Bool { process?.isRunning ?? false }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // Load DASHSCOPE_API_KEY from .env if not already set
        if env["DASHSCOPE_API_KEY"] == nil || env["DASHSCOPE_API_KEY"]!.isEmpty {
            if let key = EnvLoader.loadDashScopeAPIKey() {
                env["DASHSCOPE_API_KEY"] = key
                os_log(.info, log: bridgeLog, "Loaded DASHSCOPE_API_KEY from .env (length=%d)", key.count)
            } else {
                os_log(.error, log: bridgeLog, "DASHSCOPE_API_KEY not found in env or any .env file!")
            }
        } else {
            os_log(.info, log: bridgeLog, "DASHSCOPE_API_KEY found in environment")
        }

        return env
    }
}
