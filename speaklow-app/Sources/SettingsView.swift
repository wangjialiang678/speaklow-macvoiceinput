import SwiftUI
import AVFoundation
import ServiceManagement

// MARK: - Settings Tab Enum

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用"
    case recognition = "识别"
    case hotwords = "用户词典"
    case apiKey = "密钥"
    case advanced = "高级"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .apiKey: return "key"
        case .recognition: return "waveform"
        case .hotwords: return "text.book.closed"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var initialTab: String? = nil
    @State private var selectedTab: SettingsTab = .general

    // Bridge state
    @State private var bridgeIsHealthy: Bool? = nil
    @State private var isCheckingBridge = false

    // API Key state
    @State private var apiKeyInput = ""
    @State private var apiKeyStatus: APIKeyStatus = .unknown
    @State private var isValidatingKey = false

    // Diagnostics state
    @State private var isRunningDiagnostics = false
    @State private var diagnosticResults: [DiagnosticResult] = []

    var body: some View {
        HStack(spacing: 0) {
            // 左侧导航栏
            sidebar

            Divider()

            // 右侧内容区
            VStack(spacing: 0) {
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                versionFooter
            }
        }
        .frame(width: 600)
        .frame(minHeight: 480, idealHeight: 780, maxHeight: .infinity)
        .task { await checkBridgeHealth() }
        .onAppear {
            if let tab = initialTab, let t = SettingsTab.allCases.first(where: { $0.id == tab || String(describing: $0) == tab }) {
                selectedTab = t
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("switchSettingsTab"))) { notif in
            if let tab = notif.userInfo?["tab"] as? String,
               let t = SettingsTab.allCases.first(where: { $0.id == tab || String(describing: $0) == tab }) {
                selectedTab = t
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                HStack(spacing: 6) {
                    Image(systemName: tab.icon)
                        .frame(width: 20, alignment: .center)
                    Text(tab.rawValue)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedTab = tab }
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: 130)
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch selectedTab {
        case .general:
            generalTab
        case .apiKey:
            apiKeyTab
        case .recognition:
            recognitionTab
        case .hotwords:
            hotwordsTab
        case .advanced:
            advancedTab
        }
    }

    // MARK: - 通用 Tab

    private var generalTab: some View {
        Form {
            StatusOverviewSection(appState: appState, bridgeIsHealthy: $bridgeIsHealthy)

            Section("通用") {
                Toggle("开机自动启动", isOn: $appState.launchAtLogin)
                    .tint(.accentColor)
                    .onAppear { appState.refreshLaunchAtLoginStatus() }
            }

            Section("听写热键") {
                Picker("热键", selection: $appState.selectedHotkey) {
                    ForEach(HotkeyOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if appState.selectedHotkey == .fnKey {
                    Text("提示：如果按 Fn 会打开表情选择器，请前往系统设置 > 键盘，将「按下 fn 键时」改为「无操作」")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 密钥 Tab

    private var apiKeyTab: some View {
        Form {
            Section("API Key") {
                Text("SpeakLow 使用阿里云百炼平台的语音识别和大模型服务，需要配置 API Key 才能使用")
                    .font(.footnote).foregroundStyle(.secondary)

                HStack {
                    if apiKeyInput.isEmpty {
                        TextField("sk-...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button("保存") {
                        Task { await saveAndValidateAPIKey() }
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isValidatingKey)
                }

                // 状态指示
                HStack(spacing: 6) {
                    switch apiKeyStatus {
                    case .unknown:
                        if let key = EnvLoader.loadDashScopeAPIKey(), !key.isEmpty {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("已配置（\(maskKey(key))）")
                                .foregroundStyle(.secondary)
                        } else {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text("未配置")
                                .foregroundStyle(.red)
                        }
                    case .validating:
                        ProgressView().controlSize(.small)
                        Text("验证中...")
                            .foregroundStyle(.secondary)
                    case .valid:
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("有效（\(maskKey(apiKeyInput))）")
                            .foregroundStyle(.green)
                    case .invalid(let reason):
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text(reason)
                            .foregroundStyle(.red)
                    case .saved:
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("已保存并验证通过")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
            }

            Section("获取 API Key") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 访问阿里云百炼平台，注册或登录")
                    Text("2. 进入「API-KEY 管理」页面，创建一个新的 API Key")
                    Text("3. 复制 API Key（以 sk- 开头），粘贴到上方输入框")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                HStack {
                    Button("打开百炼平台控制台") {
                        if let url = URL(string: "https://bailian.console.aliyun.com/") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("需要在百炼平台开通模型服务（原 DashScope 灵积已迁移至百炼）", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Label("Coding Plan 的 API Key 不可用于语音识别", systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }

            Section("配置文件") {
                LabeledContent("位置") {
                    Text("~/.config/speaklow/.env")
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                Button("在 Finder 中显示") {
                    let path = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".config/speaklow")
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path.path)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 识别 Tab

    private var recognitionTab: some View {
        Form {
            Section("识别模式") {
                Picker("模式", selection: $appState.asrMode) {
                    ForEach(ASRMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch appState.asrMode {
                case .batch:
                    Text("录完后统一识别，适合网络不稳定的场景，约 1-2 秒延迟")
                        .font(.footnote).foregroundStyle(.secondary)
                case .streaming:
                    Text("边说边显示文字，延迟极低，需要稳定的网络连接。会在后台运行一个识别服务")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("AI 文字优化") {
                Toggle("启用 AI 优化", isOn: $appState.llmRefineEnabled)
                    .tint(.accentColor)
                if appState.llmRefineEnabled {
                    Picker("风格", selection: $appState.refineStyle) {
                        ForEach(RefineStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch appState.refineStyle {
                    case .default:
                        Text("纠正错字和口语化表达，顺通语句，保持你的原意不变")
                            .font(.footnote).foregroundStyle(.secondary)
                    case .business:
                        Text("改写为正式书面风格，语气严谨，适合邮件、文档、汇报")
                            .font(.footnote).foregroundStyle(.secondary)
                    case .chat:
                        Text("保持轻松自然的语气，适当加入 emoji，适合微信、Slack 等即时通讯")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            if appState.asrMode == .streaming {
                bridgeManagementSection()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 热词 Tab

    private var hotwordsTab: some View {
        Form {
            Section("用户词典") {
                Text("添加语音识别时需要优先识别的专有名词（如人名、产品名、术语）")
                    .font(.footnote).foregroundStyle(.secondary)
                HotwordEditorView(standalone: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 高级 Tab

    private var advancedTab: some View {
        Form {
            accessibilitySection()

            DiagnosticsSectionView(
                appState: appState,
                isRunningDiagnostics: $isRunningDiagnostics,
                diagnosticResults: $diagnosticResults
            )
        }
        .formStyle(.grouped)
    }

    // MARK: - Shared Sections

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

    // MARK: - Version Footer

    private var versionFooter: some View {
        Group {
            if !buildDate.isEmpty {
                Text("SpeakLow v\(appVersion) (build \(buildNumber)) · \(buildDate)")
            } else {
                Text("SpeakLow v\(appVersion) (build \(buildNumber))")
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

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

    private func maskKey(_ key: String) -> String {
        guard key.count > 8 else { return "****" }
        return String(key.prefix(3)) + "****" + String(key.suffix(4))
    }

    private func saveAndValidateAPIKey() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        apiKeyStatus = .validating
        isValidatingKey = true

        // 1. 验证 key 格式和有效性（用一个轻量 API 调用）
        let valid = await validateDashScopeKey(key)

        if valid {
            // 2. 保存到 ~/.config/speaklow/.env
            saveKeyToEnvFile(key)
            // 3. 通知运行态客户端刷新缓存的 key
            DashScopeClient.shared.reloadAPIKey()
            apiKeyStatus = .saved
            viLog("API Key 已保存并验证通过")
        }

        isValidatingKey = false
    }

    private func validateDashScopeKey(_ key: String) async -> Bool {
        // 用 DashScope models API 做轻量验证
        guard let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/models") else {
            apiKeyStatus = .invalid("URL 错误")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                apiKeyStatus = .invalid("网络错误")
                return false
            }
            if http.statusCode == 200 {
                return true
            } else if http.statusCode == 401 {
                apiKeyStatus = .invalid("API Key 无效，请检查是否正确")
                return false
            } else if http.statusCode == 403 {
                apiKeyStatus = .invalid("API Key 无权限，请确认已开通「模型服务灵积」")
                return false
            } else {
                apiKeyStatus = .invalid("验证失败（HTTP \(http.statusCode)）")
                return false
            }
        } catch {
            apiKeyStatus = .invalid("网络连接失败：\(error.localizedDescription)")
            return false
        }
    }

    private func saveKeyToEnvFile(_ key: String) {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/speaklow")
        let envPath = configDir.appendingPathComponent(".env")

        do {
            // 确保目录存在
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

            // 读取已有内容，替换或追加 DASHSCOPE_API_KEY
            var lines: [String] = []
            var keyReplaced = false

            if FileManager.default.fileExists(atPath: envPath.path),
               let content = try? String(contentsOf: envPath, encoding: .utf8) {
                for line in content.components(separatedBy: .newlines) {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("DASHSCOPE_API_KEY") {
                        lines.append("DASHSCOPE_API_KEY=\(key)")
                        keyReplaced = true
                    } else {
                        lines.append(line)
                    }
                }
            }

            if !keyReplaced {
                lines.append("DASHSCOPE_API_KEY=\(key)")
            }

            // 去掉末尾多余空行，保留一个换行
            let content = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
            try content.write(to: envPath, atomically: true, encoding: .utf8)
            viLog("API Key 已保存到 \(envPath.path)")
        } catch {
            apiKeyStatus = .invalid("保存失败：\(error.localizedDescription)")
            viLog("保存 API Key 失败: \(error)")
        }
    }

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

// MARK: - APIKeyStatus

private enum APIKeyStatus {
    case unknown
    case validating
    case valid
    case invalid(String)
    case saved
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
