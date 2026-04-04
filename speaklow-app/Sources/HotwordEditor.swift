import SwiftUI
import AppKit

// MARK: - HotwordManager

class HotwordManager {
    static let shared = HotwordManager()

    private init() {}

    var userHotwordsURL: URL {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/speaklow")
        return configDir.appendingPathComponent("hotwords.txt")
    }

    var bundleHotwordsURL: URL? {
        Bundle.main.url(forResource: "hotwords", withExtension: "txt")
    }

    private(set) var hotwords: [String] = []

    var count: Int { hotwords.count }

    /// 如果用户配置文件不存在，从 bundle 复制过来
    func ensureMigrated() {
        let dest = userHotwordsURL
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }

        do {
            let configDir = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            if let src = bundleHotwordsURL {
                try FileManager.default.copyItem(at: src, to: dest)
                viLog("[HotwordManager] 从 bundle 迁移热词文件到 \(dest.path)")
            } else {
                // bundle 里没有，创建空文件
                try "# SpeakLow 热词表\n# 每行一个热词\n".write(to: dest, atomically: true, encoding: .utf8)
                viLog("[HotwordManager] bundle 无热词文件，创建空文件: \(dest.path)")
            }
        } catch {
            viLog("[HotwordManager] 迁移失败: \(error)")
        }
    }

    /// 读取用户文件，解析热词列表（跳过注释和空行，取第一列）
    func load() {
        let url = userHotwordsURL
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            viLog("[HotwordManager] 读取热词文件失败: \(url.path)")
            hotwords = []
            return
        }
        hotwords = content.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            // 取 tab 分隔的第一列
            return trimmed.components(separatedBy: "\t").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            }.flatMap { $0.isEmpty ? nil : $0 }
        }
        viLog("[HotwordManager] 已加载 \(hotwords.count) 个热词")
    }

    /// 将热词写回文件（每行一个，简单格式），并自动触发 ASR 热词重载
    func save() {
        let url = userHotwordsURL
        let content = "# SpeakLow 热词表\n# 每行一个热词\n" + hotwords.joined(separator: "\n") + "\n"
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            viLog("[HotwordManager] 已保存 \(hotwords.count) 个热词")
            triggerReload()
        } catch {
            viLog("[HotwordManager] 保存热词文件失败: \(error)")
        }
    }

    /// 通知 Swift DashScopeClient 和 Go bridge 重载热词
    func triggerReload() {
        // 1. Swift 端：直接调用 DashScopeClient 重载
        DashScopeClient.shared.reloadCorpusText()
        viLog("[HotwordManager] Swift 端热词已重载")

        // 2. Go bridge 端：POST /v1/reload-hotwords
        guard let url = URL(string: "http://localhost:18089/v1/reload-hotwords") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                viLog("[HotwordManager] Bridge 端热词已重载")
            } else if let error {
                viLog("[HotwordManager] Bridge 热词重载失败（bridge 可能未运行）: \(error.localizedDescription)")
            }
        }.resume()
    }

    func add(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !hotwords.contains(trimmed) else { return }
        hotwords.append(trimmed)
        save()
    }

    func remove(at index: Int) {
        guard hotwords.indices.contains(index) else { return }
        hotwords.remove(at: index)
        save()
    }
}

// MARK: - HotwordEditorView

struct HotwordEditorView: View {
    /// standalone 模式下始终展开，不显示折叠按钮（用于独立 tab）
    var standalone: Bool = false

    @State private var isExpanded = false
    @State private var hotwords: [String] = []
    @State private var newWord = ""
    @State private var statusMessage: String?

    private var showContent: Bool { standalone || isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 折叠/展开切换行（standalone 模式隐藏）
            if !standalone {
                HStack {
                    Text("当前：\(hotwords.count) 个热词")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(isExpanded ? "收起" : "编辑热词...") {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .font(.callout)
                }
            }

            if showContent {
                VStack(alignment: .leading, spacing: 6) {
                    // 热词列表
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(hotwords.enumerated()), id: \.element) { index, word in
                                HStack {
                                    Text(word)
                                        .font(.body)
                                    Spacer()
                                    Button {
                                        let removed = hotwords[index]
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            HotwordManager.shared.remove(at: index)
                                            hotwords = HotwordManager.shared.hotwords
                                        }
                                        showStatus("已删除「\(removed)」，已生效")
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .transition(.opacity)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: standalone ? 320 : 240)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )

                    // 添加新热词
                    HStack {
                        TextField("输入新热词", text: $newWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addWord() }
                        Button("添加") { addWord() }
                            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    // 底部信息行
                    HStack {
                        Text("共 \(hotwords.count) 个")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let msg = statusMessage {
                            Text("· \(msg)")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .transition(.opacity)
                        }

                        Spacer()
                        Button("在编辑器中打开原始文件") {
                            NSWorkspace.shared.open(HotwordManager.shared.userHotwordsURL)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .font(.caption)
                    }
                }
            }
        }
        .onAppear {
            HotwordManager.shared.ensureMigrated()
            HotwordManager.shared.load()
            hotwords = HotwordManager.shared.hotwords
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 用户从外部编辑器切回来时，检查文件是否变更
            let oldCount = hotwords.count
            HotwordManager.shared.load()
            let newList = HotwordManager.shared.hotwords
            if newList != hotwords {
                hotwords = newList
                HotwordManager.shared.triggerReload()
                showStatus("检测到外部修改，已生效")
                viLog("[HotwordEditor] 检测到外部修改，已重载（\(oldCount) → \(newList.count) 个热词）")
            }
        }
    }

    private func showStatus(_ message: String) {
        withAnimation { statusMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { statusMessage = nil }
        }
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        HotwordManager.shared.add(trimmed)
        hotwords = HotwordManager.shared.hotwords
        newWord = ""
        showStatus("已添加「\(trimmed)」，已生效")
    }
}
