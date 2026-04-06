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

        // 0. 检查端口是否已被占用（旧 bridge 进程残留）
        if isPortInUse(18089) {
            os_log(.info, log: bridgeLog, "端口 18089 已被占用，尝试健康检查...")
            // 异步检查旧进程是否健康，若健康则直接接管，若不健康则尝试杀死再继续
            Task {
                let service = TranscriptionService()
                if await service.checkHealth() {
                    // 旧 bridge 健康，直接接管，不启动新进程
                    os_log(.info, log: bridgeLog, "检测到已有健康的 bridge 进程，直接接管（跳过启动）")
                    viLog("检测到已运行的 Bridge 进程（端口 18089），直接接管")
                    await MainActor.run {
                        self.consecutiveRestarts = 0
                    }
                    return
                }
                // 旧进程不健康，尝试杀死占用端口的进程
                os_log(.info, log: bridgeLog, "端口 18089 被占用但 bridge 不健康，尝试释放端口...")
                viLog("Bridge 端口 18089 被旧进程占用且不健康，尝试杀死旧进程...")
                killProcessOnPort(18089)
                // 稍等端口释放后再启动
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    do {
                        try self.launchBridgeProcess()
                    } catch {
                        os_log(.error, log: bridgeLog, "释放端口后启动 bridge 失败: %{public}@", error.localizedDescription)
                        viLog("释放端口后启动 Bridge 失败：\(error.localizedDescription)")
                    }
                }
            }
            return
        }

        try launchBridgeProcess()
    }

    private func launchBridgeProcess() throws {
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

                // 指数退避延迟：1s, 2s, 4s
                let delay = pow(2.0, Double(self.consecutiveRestarts - 1))
                viLog("Bridge 崩溃（exit \(process.terminationStatus)），\(Int(delay)) 秒后自动重启（第 \(self.consecutiveRestarts)/\(self.maxConsecutiveRestarts) 次）...")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    do {
                        try self.launchBridgeProcess()
                    } catch {
                        os_log(.error, log: bridgeLog, "自动重启失败: %{public}@", error.localizedDescription)
                    }
                }
            }
        }

        try proc.run()
        process = proc
        os_log(.info, log: bridgeLog, "Started asr-bridge pid=%d", proc.processIdentifier)

        // 4. Poll /health up to 5 seconds — 只有 OUR 进程还在运行时才重置重启计数器
        Task {
            let service = TranscriptionService()
            let pid = proc.processIdentifier
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if await service.checkHealth() {
                    await MainActor.run {
                        // 只有当健康响应确实来自我们启动的进程时才重置计数器
                        if self.process?.isRunning == true && self.process?.processIdentifier == pid {
                            self.consecutiveRestarts = 0
                            os_log(.info, log: bridgeLog, "asr-bridge is READY (pid=%d)", pid)
                        } else {
                            os_log(.info, log: bridgeLog, "asr-bridge 健康响应来自其他进程，不重置重启计数器 (expected pid=%d)", pid)
                        }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            os_log(.error, log: bridgeLog, "asr-bridge health check TIMED OUT after 5s")
        }
    }

    /// 检测指定端口是否已有进程在监听
    private func isPortInUse(_ port: Int) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    /// 杀死占用指定端口的进程
    private func killProcessOnPort(_ port: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let pids = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } ?? []
            for pid in pids {
                os_log(.info, log: bridgeLog, "杀死占用端口 18089 的进程 pid=%d", pid)
                kill(pid, SIGTERM)
            }
        } catch {
            os_log(.error, log: bridgeLog, "killProcessOnPort 失败: %{public}@", error.localizedDescription)
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
        try launchBridgeProcess()
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
