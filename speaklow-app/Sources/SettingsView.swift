import SwiftUI
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    // MARK: - Bridge state
    @State private var bridgeIsHealthy: Bool? = nil
    @State private var isCheckingBridge = false

    // MARK: - Diagnostics state
    @State private var isRunningDiagnostics = false
    @State private var diagnosticResults: [DiagnosticResult] = []

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Form {
                statusOverviewSection()
                generalSection()
                hotkeySection()
                asrModeSection()
                aiRefineSection()
                hotwordSection()
                if appState.asrMode == .streaming {
                    bridgeManagementSection()
                }
                accessibilitySection()
                diagnosticsSection()
            }
            .formStyle(.grouped)
            .frame(minWidth: 480)
            .fixedSize(horizontal: false, vertical: true)

            // 版本信息（Form 外部）
            if !buildDate.isEmpty {
                Text("SpeakLow v\(appVersion) (build \(buildNumber)) · \(buildDate)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
            } else {
                Text("SpeakLow v\(appVersion) (build \(buildNumber))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func statusOverviewSection() -> some View {
        StatusOverviewSection(appState: appState, bridgeIsHealthy: $bridgeIsHealthy)
            .task { await checkBridgeHealth() }
    }

    @ViewBuilder
    private func generalSection() -> some View {
        Section("通用") {
            Toggle("开机自动启动", isOn: $appState.launchAtLogin)
                .onAppear { appState.refreshLaunchAtLoginStatus() }
        }
    }

    @ViewBuilder
    private func hotkeySection() -> some View {
        Section {
            Picker("热键", selection: $appState.selectedHotkey) {
                ForEach(HotkeyOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("听写热键")
        } footer: {
            if appState.selectedHotkey == .fnKey {
                Text("提示：如果按 Fn 会打开表情选择器，请前往系统设置 > 键盘，将「按下 fn 键时」改为「无操作」")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func asrModeSection() -> some View {
        Section {
            Picker("模式", selection: $appState.asrMode) {
                ForEach(ASRMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("识别模式")
        } footer: {
            switch appState.asrMode {
            case .batch:
                Text("录完后统一识别，无需后台服务，适合网络不稳定或低功耗场景，约 1-2 秒延迟")
            case .streaming:
                Text("边说边实时显示文字，延迟极低，需要运行后台服务（见下方「后台服务」）")
            }
        }
    }

    @ViewBuilder
    private func aiRefineSection() -> some View {
        Section {
            Toggle("启用 AI 优化", isOn: $appState.llmRefineEnabled)
            if appState.llmRefineEnabled {
                Picker("风格", selection: $appState.refineStyle) {
                    ForEach(RefineStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("AI 文字优化")
        } footer: {
            if appState.llmRefineEnabled {
                switch appState.refineStyle {
                case .default:
                    Text("纠正错字和口语化表达，顺通语句，保持你的原意不变")
                case .business:
                    Text("改写为正式书面风格，语气严谨，适合邮件、文档、汇报")
                case .chat:
                    Text("保持轻松自然的语气，适当加入 emoji，适合微信、Slack 等即时通讯")
                }
            }
        }
    }

    @ViewBuilder
    private func hotwordSection() -> some View {
        Section {
            HotwordEditorView()
        } header: {
            Text("热词")
        } footer: {
            Text("管理识别时优先识别的专有名词（如人名、产品名、术语）")
        }
    }

    @ViewBuilder
    private func bridgeManagementSection() -> some View {
        Section("后台服务") {
            HStack {
                Circle()
                    .fill(
                        bridgeIsHealthy == true ? Color.green :
                        (bridgeIsHealthy == nil ? Color.yellow : Color.red)
                    )
                    .frame(width: 8, height: 8)
                Text(bridgeStatusText)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Button("检查状态") {
                    Task { await checkBridgeHealth() }
                }
                .disabled(isCheckingBridge)

                Button("重启服务") {
                    try? appState.bridgeManager?.restart()
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await checkBridgeHealth()
                    }
                }

                if bridgeIsHealthy == true {
                    Button("停止服务") {
                        appState.bridgeManager?.stop()
                        bridgeIsHealthy = false
                    }
                } else {
                    Button("启动服务") {
                        try? appState.bridgeManager?.start()
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            await checkBridgeHealth()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accessibilitySection() -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("当 SpeakLow 无法自动插入文字时，可通过重新授权来恢复：")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("1. 点击下方按钮，打开系统辅助功能设置")
                    Text("2. 在列表中找到 SpeakLow，点击 − 按钮删除")
                    Text("3. 从安装目录重新添加 SpeakLow 并勾选开关")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("当前位置：\(Bundle.main.bundlePath)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                HStack {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.selectFile(Bundle.main.bundlePath, inFileViewerRootedAtPath: "")
                    }
                    Button("打开辅助功能设置...") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        } header: {
            Text("重新授权辅助功能")
        }
    }

    @ViewBuilder
    private func diagnosticsSection() -> some View {
        DiagnosticsSectionView(
            appState: appState,
            isRunningDiagnostics: $isRunningDiagnostics,
            diagnosticResults: $diagnosticResults
        )
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return mins > 0 ? "\(mins) 分 \(secs) 秒" : "\(secs) 秒"
    }

    private var bridgeStatusText: String {
        if isCheckingBridge { return "检查中..." }
        switch bridgeIsHealthy {
        case .some(true): return "运行中 (localhost:18089)"
        case .some(false): return "已停止"
        case .none: return "状态未知"
        }
    }

    private func checkBridgeHealth() async {
        isCheckingBridge = true
        let service = TranscriptionService()
        bridgeIsHealthy = await service.checkHealth()
        isCheckingBridge = false
    }

    // MARK: - Version info

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var buildDate: String {
        Bundle.main.infoDictionary?["BuildDate"] as? String ?? ""
    }
}

// MARK: - StatusOverviewSection

private struct StatusOverviewSection: View {
    let appState: AppState
    @Binding var bridgeIsHealthy: Bool?

    var body: some View {
        Section {
            statusRows
        } header: {
            Text("状态总览")
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        LabeledContent("当前模式") {
            Text(appState.asrMode.displayName)
        }

        if appState.asrMode == .streaming {
            LabeledContent("后台服务") {
                HStack {
                    Circle()
                        .fill(bridgeIsHealthy == true ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(bridgeIsHealthy == true ? "运行中" : "已停止")
                }
            }
        }

        LabeledContent("辅助功能") {
            if appState.hasAccessibility {
                Text("已授权").foregroundStyle(.secondary)
            } else {
                Text("未授权").foregroundStyle(Color.red)
            }
        }

        if appState.statsTodayCount > 0 {
            LabeledContent("今日") {
                Text("识别 \(appState.statsTodayCount) 次 · \(appState.statsTodayChars) 字 · 用时 \(formatDuration(appState.statsTodayDuration))")
            }
            LabeledContent("平均速度") {
                Text("\(appState.averageSpeakingSpeed) 字/分钟")
            }
        }

        if appState.statsTotalCount > 0 {
            LabeledContent("累计") {
                Text("\(appState.statsTotalCount) 次 · \(appState.statsTotalChars) 字")
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return mins > 0 ? "\(mins) 分 \(secs) 秒" : "\(secs) 秒"
    }
}

// MARK: - DiagnosticsSectionView

private struct DiagnosticsSectionView: View {
    let appState: AppState
    @Binding var isRunningDiagnostics: Bool
    @Binding var diagnosticResults: [DiagnosticResult]

    var body: some View {
        Section("诊断") {
            HStack {
                Button("运行诊断") {
                    Task { await runDiagnostics() }
                }
                .disabled(isRunningDiagnostics)

                if isRunningDiagnostics {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button("导出诊断日志...") {
                    DiagnosticExporter.exportWithSavePanel()
                }
            }

            Button("重新运行初始引导...") {
                NotificationCenter.default.post(name: .showSetup, object: nil)
            }

            if !diagnosticResults.isEmpty {
                Divider()

                ForEach(diagnosticResults, id: \.name) { result in
                    HStack(alignment: .top) {
                        Image(systemName: diagnosticIcon(for: result.status))
                            .foregroundStyle(diagnosticColor(for: result.status))

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(result.name)
                                Text(result.detail)
                                    .foregroundStyle(.secondary)
                                if result.autoFixed {
                                    Text("(已自动修复)")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                }
                            }
                            if let suggestion = result.suggestion {
                                Text(suggestion)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("导出诊断日志...") {
                        DiagnosticExporter.exportWithSavePanel()
                    }
                    Button("关闭") {
                        diagnosticResults = []
                    }
                }
            }
        }
    }

    private func runDiagnostics() async {
        isRunningDiagnostics = true
        viLog("SettingsView: 开始运行诊断")
        let runner = DiagnosticRunner()
        diagnosticResults = await runner.run(asrMode: appState.asrMode, bridgeManager: appState.bridgeManager)
        viLog("SettingsView: 诊断完成，共 \(diagnosticResults.count) 项")
        isRunningDiagnostics = false
    }

    private func diagnosticIcon(for status: DiagnosticResult.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func diagnosticColor(for status: DiagnosticResult.Status) -> Color {
        switch status {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .skipped: return .secondary
        }
    }
}
