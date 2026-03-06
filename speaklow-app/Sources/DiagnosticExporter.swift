import Foundation
import AppKit

class DiagnosticExporter {

    /// 导出诊断包，弹出保存面板让用户选择位置
    static func exportWithSavePanel() {
        let panel = NSSavePanel()
        let timestamp = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            return fmt.string(from: Date())
        }()
        panel.nameFieldStringValue = "SpeakLow-diag-\(timestamp).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let saveURL = panel.url else { return }
            do {
                try Self.exportTo(saveURL)
                NSWorkspace.shared.selectFile(saveURL.path, inFileViewerRootedAtPath: saveURL.deletingLastPathComponent().path)
                viLog("诊断包已导出: \(saveURL.path)")
            } catch {
                viLog("诊断包导出失败: \(error)")
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    static func exportTo(_ zipURL: URL) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("speaklow-diag-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // 1. 复制日志文件
        let logsDir = NSHomeDirectory() + "/Library/Logs"
        for logName in ["SpeakLow.log", "SpeakLow.log.1.log", "SpeakLow-bridge.log", "SpeakLow-bridge.log.1.log"] {
            let src = logsDir + "/" + logName
            if fm.fileExists(atPath: src) {
                try? fm.copyItem(atPath: src, toPath: tempDir.appendingPathComponent(logName).path)
            }
        }

        // 2. 系统信息
        let sysInfo = collectSystemInfo()
        try sysInfo.write(to: tempDir.appendingPathComponent("system-info.txt"), atomically: true, encoding: .utf8)

        // 3. 配置信息（脱敏）
        let config = collectConfig()
        try config.write(to: tempDir.appendingPathComponent("config.txt"), atomically: true, encoding: .utf8)

        // 4. 最近 3 个录音文件
        let recordingsDir = NSHomeDirectory() + "/Library/Caches/SpeakLow/recordings"
        if fm.fileExists(atPath: recordingsDir) {
            let recordingsDestDir = tempDir.appendingPathComponent("recordings")
            try fm.createDirectory(at: recordingsDestDir, withIntermediateDirectories: true)
            if let files = try? fm.contentsOfDirectory(atPath: recordingsDir) {
                let wavFiles = files.filter { $0.hasSuffix(".wav") }.sorted().suffix(3)
                for file in wavFiles {
                    try? fm.copyItem(
                        atPath: recordingsDir + "/" + file,
                        toPath: recordingsDestDir.appendingPathComponent(file).path
                    )
                }
            }
        }

        // 5. 打包为 zip（使用 Process 调用 zip 命令）
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.arguments = ["-r", "-q", zipURL.path, "."]
        zipProcess.currentDirectoryURL = tempDir
        try zipProcess.run()
        zipProcess.waitUntilExit()

        guard zipProcess.terminationStatus == 0 else {
            throw NSError(domain: "DiagnosticExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "zip 命令执行失败"])
        }
    }

    private static func collectSystemInfo() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let arch = {
            #if arch(arm64)
            return "arm64"
            #else
            return "x86_64"
            #endif
        }()
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        return """
        SpeakLow 诊断信息
        =================
        App 版本: \(appVersion) (\(buildNumber))
        macOS: \(version)
        架构: \(arch)
        时间: \(ISO8601DateFormatter().string(from: Date()))
        """
    }

    private static func collectConfig() -> String {
        let defaults = UserDefaults.standard
        let asrMode = defaults.string(forKey: "asr_mode") ?? "streaming"
        let hotkey = defaults.string(forKey: "selected_hotkey") ?? "rightOption"
        let refineEnabled = defaults.bool(forKey: "llm_refine_enabled")
        let refineStyle = defaults.string(forKey: "refine_style") ?? "default"

        return """
        SpeakLow 配置（脱敏）
        ====================
        ASR 模式: \(asrMode)
        热键: \(hotkey)
        LLM 优化: \(refineEnabled ? "开启" : "关闭")
        优化风格: \(refineStyle)
        API Key: [已隐藏]
        """
    }
}
