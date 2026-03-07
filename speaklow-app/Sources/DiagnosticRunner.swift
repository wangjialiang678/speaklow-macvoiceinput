import Foundation
import AVFoundation
import Network
import ApplicationServices

// MARK: - DiagnosticResult

struct DiagnosticResult {
    enum Status: String {
        case pass, warn, fail, skipped
    }

    let name: String
    let status: Status
    let detail: String
    let autoFixed: Bool
    let suggestion: String?
}

// MARK: - DiagnosticRunner

class DiagnosticRunner {
    private final class NetworkResumeState: @unchecked Sendable {
        var resumed = false
    }

    /// Run all diagnostic checks in order
    func run(asrMode: ASRMode, bridgeManager: ASRBridgeManager?) async -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []

        // 1. API Key check
        let apiKeyResult = checkAPIKey()
        results.append(apiKeyResult)

        // 2. Network connectivity
        let networkResult = await checkNetwork()
        results.append(networkResult)

        // 3. Bridge health (streaming mode only)
        if asrMode == .streaming {
            let bridgeResult = await checkBridgeHealth(bridgeManager: bridgeManager)
            results.append(bridgeResult)
        }

        // 4. Permissions
        results.append(contentsOf: checkPermissions())

        // 5. Log analysis
        let logResult = analyzeRecentLogs()
        results.append(logResult)

        // 6. AI analysis (only if API Key + network OK)
        if apiKeyResult.status == .pass && networkResult.status == .pass {
            if let aiResult = await aiAnalyzeLogs(logSummary: logResult.detail) {
                results.append(aiResult)
            }
        }

        return results
    }

    // MARK: - Individual Checks

    private func checkAPIKey() -> DiagnosticResult {
        let key = EnvLoader.loadDashScopeAPIKey()
        if let key = key, !key.isEmpty {
            return DiagnosticResult(name: "API Key", status: .pass, detail: "已配置", autoFixed: false, suggestion: nil)
        }
        return DiagnosticResult(
            name: "API Key",
            status: .fail,
            detail: "未找到 API Key",
            autoFixed: false,
            suggestion: "请在 ~/.config/speaklow/.env 中配置 DASHSCOPE_API_KEY"
        )
    }

    private func checkNetwork() async -> DiagnosticResult {
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "dashscope.aliyuncs.com", port: 443, using: .tcp)
            let queue = DispatchQueue(label: "diagnostic.network")
            let state = NetworkResumeState()

            connection.stateUpdateHandler = { connectionState in
                guard !state.resumed else { return }
                switch connectionState {
                case .ready:
                    state.resumed = true
                    connection.cancel()
                    continuation.resume(returning: DiagnosticResult(
                        name: "网络连通性",
                        status: .pass,
                        detail: "dashscope.aliyuncs.com:443 连接正常",
                        autoFixed: false,
                        suggestion: nil
                    ))
                case .failed(let error):
                    state.resumed = true
                    connection.cancel()
                    continuation.resume(returning: DiagnosticResult(
                        name: "网络连通性",
                        status: .fail,
                        detail: "连接失败: \(error.localizedDescription)",
                        autoFixed: false,
                        suggestion: "请检查网络连接或代理设置"
                    ))
                default:
                    break
                }
            }

            connection.start(queue: queue)

            // Timeout after 5 seconds
            queue.asyncAfter(deadline: .now() + 5) {
                guard !state.resumed else { return }
                state.resumed = true
                connection.cancel()
                continuation.resume(returning: DiagnosticResult(
                    name: "网络连通性",
                    status: .fail,
                    detail: "连接超时（5 秒）",
                    autoFixed: false,
                    suggestion: "请检查网络连接或代理设置"
                ))
            }
        }
    }

    private func checkBridgeHealth(bridgeManager: ASRBridgeManager?) async -> DiagnosticResult {
        guard let bridge = bridgeManager else {
            return DiagnosticResult(
                name: "后台服务",
                status: .fail,
                detail: "Bridge 管理器不可用",
                autoFixed: false,
                suggestion: "请重启应用"
            )
        }

        let service = TranscriptionService()
        let healthy = await service.checkHealth()

        if healthy {
            return DiagnosticResult(
                name: "后台服务",
                status: .pass,
                detail: "运行中 (localhost:18089)",
                autoFixed: false,
                suggestion: nil
            )
        }

        // Try auto-restart
        viLog("DiagnosticRunner: Bridge unhealthy, attempting restart...")
        do {
            try bridge.restart()
            // Wait 5 seconds for startup
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let healthyAfterRestart = await service.checkHealth()
            if healthyAfterRestart {
                return DiagnosticResult(
                    name: "后台服务",
                    status: .pass,
                    detail: "已自动重启",
                    autoFixed: true,
                    suggestion: nil
                )
            }
        } catch {
            viLog("DiagnosticRunner: Bridge restart failed: \(error)")
        }

        return DiagnosticResult(
            name: "后台服务",
            status: .fail,
            detail: "后台服务无法启动",
            autoFixed: false,
            suggestion: "请导出诊断日志排查问题"
        )
    }

    private func checkPermissions() -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []

        // Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .authorized {
            results.append(DiagnosticResult(
                name: "麦克风权限",
                status: .pass,
                detail: "已授权",
                autoFixed: false,
                suggestion: nil
            ))
        } else {
            results.append(DiagnosticResult(
                name: "麦克风权限",
                status: .fail,
                detail: "未授权",
                autoFixed: false,
                suggestion: "请在系统设置 > 隐私与安全性 > 麦克风中授权 SpeakLow"
            ))
        }

        // Accessibility
        let axTrusted = AXIsProcessTrusted()
        if axTrusted {
            results.append(DiagnosticResult(
                name: "辅助功能权限",
                status: .pass,
                detail: "已授权",
                autoFixed: false,
                suggestion: nil
            ))
        } else {
            results.append(DiagnosticResult(
                name: "辅助功能权限",
                status: .warn,
                detail: "未授权",
                autoFixed: false,
                suggestion: "请重新授权辅助功能（见设置中的操作指引）"
            ))
        }

        return results
    }

    private func analyzeRecentLogs() -> DiagnosticResult {
        let logPath = NSHomeDirectory() + "/Library/Logs/SpeakLow.log"
        guard FileManager.default.fileExists(atPath: logPath),
              let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else {
            return DiagnosticResult(
                name: "日志分析",
                status: .pass,
                detail: "无日志文件",
                autoFixed: false,
                suggestion: nil
            )
        }

        let lines = content.components(separatedBy: .newlines)
        let recentLines = Array(lines.suffix(200))
        let errorLines = recentLines.filter { $0.contains("ERROR") || $0.contains("error:") }
        let errorCount = errorLines.count

        var detail = ""
        var suggestion: String? = nil

        if errorCount == 0 {
            detail = "最近 200 行日志无错误"
        } else {
            detail = "发现 \(errorCount) 条错误"
            if let lastError = errorLines.last {
                detail += "\n最近: \(String(lastError.prefix(120)))"
            }

            // Known pattern matching
            let allRecent = recentLines.joined(separator: "\n")
            if allRecent.contains("DASHSCOPE_API_KEY not found") {
                suggestion = "未找到 API Key，请确认 ~/.config/speaklow/.env 配置"
            } else if allRecent.contains("WS connect failed") {
                suggestion = "WebSocket 连接失败，请检查网络或防火墙设置"
            } else if allRecent.contains("连续重启超过上限") {
                suggestion = "后台服务反复崩溃，可能是 API Key 或网络配置问题"
            }
        }

        return DiagnosticResult(
            name: "日志分析",
            status: errorCount > 0 ? .warn : .pass,
            detail: detail,
            autoFixed: false,
            suggestion: suggestion
        )
    }

    private func aiAnalyzeLogs(logSummary: String) async -> DiagnosticResult? {
        guard !logSummary.isEmpty,
              logSummary != "无日志文件",
              logSummary != "最近 200 行日志无错误" else {
            return nil
        }

        // Read recent log lines for AI analysis
        let logPath = NSHomeDirectory() + "/Library/Logs/SpeakLow.log"
        guard let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines)
        let recentLines = Array(lines.suffix(50)).joined(separator: "\n")

        let systemInfo = """
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        App: SpeakLow \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
        """

        let prompt = "请分析以下应用日志，识别异常模式，给出 1-3 条简短建议：\n\n系统信息：\n\(systemInfo)\n\n最近日志：\n\(recentLines)"
        let analysis = await DashScopeClient.shared.refine(text: prompt, style: .default)

        if !analysis.isEmpty, analysis != prompt {
            return DiagnosticResult(
                name: "AI 分析",
                status: .warn,
                detail: analysis,
                autoFixed: false,
                suggestion: nil
            )
        }

        return nil
    }
}
