import Foundation
import os.log

private let bridgeLog = OSLog(subsystem: "com.speaklow.app", category: "ASRBridge")

class ASRBridgeManager {
    private var process: Process?
    private var isStopping = false
    private var healthTimer: Timer?
    private var consecutiveHealthFailures = 0
    private var consecutiveRestarts = 0
    private let maxConsecutiveRestarts = 3

    func start() throws {
        isStopping = false
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
            throw NSError(
                domain: "ASRBridgeManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "找不到 asr-bridge 二进制文件"]
            )
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
            DispatchQueue.main.async {
                guard let self else { return }
                os_log(.info, log: bridgeLog, "asr-bridge terminated with exit code %d", process.terminationStatus)
                self.process = nil
                guard !self.isStopping else { return }

                self.consecutiveRestarts += 1
                if self.consecutiveRestarts > self.maxConsecutiveRestarts {
                    os_log(.error, log: bridgeLog, "asr-bridge 连续重启超过上限（%d），停止自动重启", self.maxConsecutiveRestarts)
                    viLog("Bridge 连续重启超过 \(self.maxConsecutiveRestarts) 次，停止自动重启，请检查配置")
                    return
                }

                viLog("Bridge 崩溃（exit \(process.terminationStatus)），1 秒后自动重启（第 \(self.consecutiveRestarts)/\(self.maxConsecutiveRestarts) 次）...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    do {
                        try self.start()
                    } catch {
                        os_log(.error, log: bridgeLog, "自动重启失败: %{public}@", error.localizedDescription)
                    }
                }
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
                    await MainActor.run {
                        self.consecutiveRestarts = 0
                    }
                    os_log(.info, log: bridgeLog, "asr-bridge is READY")
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            os_log(.error, log: bridgeLog, "asr-bridge health check TIMED OUT after 5s")
        }
    }

    func stop() {
        isStopping = true
        stopHealthMonitor()
        os_log(.info, log: bridgeLog, "Stopping asr-bridge...")
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        os_log(.info, log: bridgeLog, "asr-bridge stopped")
    }

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Health Monitor

    /// 启动定时健康检查（仅 streaming 模式需要）
    func startHealthMonitor() {
        stopHealthMonitor()
        consecutiveHealthFailures = 0
        viLog("Bridge health monitor: started (30s interval)")
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.healthTimer != nil else { return }
            Task {
                let service = TranscriptionService()
                let healthy = await service.checkHealth()
                await MainActor.run {
                    if healthy {
                        self.consecutiveHealthFailures = 0
                        self.consecutiveRestarts = 0
                    } else {
                        self.consecutiveHealthFailures += 1
                        viLog("Bridge health check failed (\(self.consecutiveHealthFailures) consecutive)")
                        if self.consecutiveHealthFailures >= 2 {
                            viLog("Bridge health: 2 consecutive failures, auto-restarting...")
                            self.consecutiveHealthFailures = 0
                            try? self.restart()
                        }
                    }
                }
            }
        }
    }

    /// 停止定时健康检查
    func stopHealthMonitor() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// Restart the bridge process (stop then start).
    func restart() throws {
        os_log(.info, log: bridgeLog, "Restarting asr-bridge...")
        stop()
        try start()
    }

    /// Check bridge health; if unhealthy, restart and wait for it to become ready.
    /// Returns true if bridge is healthy after the attempt.
    func ensureRunning() async -> Bool {
        let service = TranscriptionService()

        // Quick check — if already healthy, return immediately
        if await service.checkHealth() {
            await MainActor.run {
                self.consecutiveRestarts = 0
            }
            os_log(.info, log: bridgeLog, "ensureRunning: bridge already healthy")
            return true
        }

        os_log(.info, log: bridgeLog, "ensureRunning: bridge unhealthy, attempting restart...")

        // Restart on main thread (Process management)
        do {
            try await MainActor.run {
                try self.restart()
            }
        } catch {
            os_log(.error, log: bridgeLog, "ensureRunning: restart failed: %{public}@", error.localizedDescription)
            return false
        }

        // Poll health for up to 5 seconds after restart
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await service.checkHealth() {
                await MainActor.run {
                    self.consecutiveRestarts = 0
                }
                os_log(.info, log: bridgeLog, "ensureRunning: bridge is READY after restart")
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        os_log(.error, log: bridgeLog, "ensureRunning: bridge still unhealthy after restart")
        return false
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // 始终优先使用 .env 文件中的 key，避免继承 shell 环境中的错误 key
        if let key = EnvLoader.loadKeyFromConfigFiles() {
            env["DASHSCOPE_API_KEY"] = key
            os_log(.info, log: bridgeLog, "DASHSCOPE_API_KEY loaded from .env (length=%d)", key.count)
        } else if let existing = env["DASHSCOPE_API_KEY"], !existing.isEmpty {
            os_log(.info, log: bridgeLog, "DASHSCOPE_API_KEY using inherited environment")
        } else {
            os_log(.error, log: bridgeLog, "DASHSCOPE_API_KEY not found in .env or environment!")
        }

        return env
    }
}
