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

    /// 将热词写回文件（每行一个，简单格式）
    func save() {
        let url = userHotwordsURL
        let content = "# SpeakLow 热词表\n# 每行一个热词\n" + hotwords.joined(separator: "\n") + "\n"
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            viLog("[HotwordManager] 已保存 \(hotwords.count) 个热词")
        } catch {
            viLog("[HotwordManager] 保存热词文件失败: \(error)")
        }
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
    @State private var isExpanded = false
    @State private var hotwords: [String] = []
    @State private var newWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 折叠/展开切换行
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

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // 热词列表
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(hotwords.enumerated()), id: \.offset) { index, word in
                                HStack {
                                    Text(word)
                                        .font(.body)
                                    Spacer()
                                    Button {
                                        HotwordManager.shared.remove(at: index)
                                        hotwords = HotwordManager.shared.hotwords
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 240)
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
                        Text("共 \(hotwords.count) 个热词")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        HotwordManager.shared.add(trimmed)
        hotwords = HotwordManager.shared.hotwords
        newWord = ""
    }
}
