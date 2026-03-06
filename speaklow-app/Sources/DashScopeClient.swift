import Foundation

// MARK: - Error Types

enum DashScopeError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(Int, String)
    case parseFailed
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "DashScope API Key not configured"
        case .invalidResponse: return "Invalid response from DashScope"
        case .httpError(let code, let detail): return "DashScope HTTP \(code): \(detail.prefix(100))"
        case .parseFailed: return "Failed to parse DashScope response"
        case .audioConversionFailed: return "Audio conversion to 16kHz mono failed"
        }
    }
}

// MARK: - Refine Style

enum RefineStyle: String {
    case `default` = "default"
    case business = "business"
    case chat = "chat"
}

// MARK: - DashScopeClient

/// Swift 端直接调用 DashScope API（不经过 Go bridge）
final class DashScopeClient {
    static let shared = DashScopeClient()

    private let apiKey: String?
    private let corpusText: String
    private let preamble: String
    private let promptText: String
    private var styleRules: [String: String] = [:]

    private init() {
        // 1. API Key
        apiKey = EnvLoader.loadDashScopeAPIKey()

        // 2. 热词加载 - 从 bundle Resources/hotwords.txt
        corpusText = DashScopeClient.loadCorpusText()

        // 3. Refine prompt 文件加载
        preamble = DashScopeClient.loadBundleText("refine_preamble") ?? ""
        promptText = DashScopeClient.loadBundleText("refine_prompt") ?? ""

        // 4. Style rules
        for style in ["business", "chat"] {
            if let rule = DashScopeClient.loadBundleText("refine_styles/\(style)") {
                styleRules[style] = rule
            }
        }

        viLog("DashScopeClient init: apiKey=\(apiKey != nil), corpus=\(corpusText.count) chars, preamble=\(preamble.count) chars")
    }

    // MARK: - Private Helpers

    private static func loadCorpusText() -> String {
        guard let url = Bundle.main.url(forResource: "hotwords", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }

        var words: [String] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // 格式: 热词<TAB>权重<TAB>src_lang<TAB>target_lang<TAB>音近提示(可选)
            let cols = trimmed.components(separatedBy: "\t")
            guard !cols.isEmpty else { continue }
            let word = cols[0].trimmingCharacters(in: .whitespaces)
            if word.isEmpty { continue }
            // 如果有第5列（音近提示），格式为 "word（音近提示）"
            if cols.count >= 5 {
                let hint = cols[4].trimmingCharacters(in: .whitespaces)
                if !hint.isEmpty {
                    words.append("\(word)（\(hint)）")
                    continue
                }
            }
            words.append(word)
        }

        if words.isEmpty { return "" }
        return "本次对话涉及 AI 开发技术，以下专有名词可能出现\n（括号内为中文音近说法，听到时请输出英文原文）：\n" + words.joined(separator: ", ")
    }

    private static func loadBundleText(_ name: String) -> String? {
        // 处理子目录路径如 "refine_styles/business"
        let components = name.components(separatedBy: "/")
        let url: URL?
        if components.count == 2 {
            url = Bundle.main.url(forResource: components[1], withExtension: "txt", subdirectory: components[0])
        } else {
            url = Bundle.main.url(forResource: name, withExtension: "txt")
        }
        guard let fileURL = url else { return nil }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private func convertTo16kMono(fileURL: URL) throws -> URL {
        let convertedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_16k.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", fileURL.path, convertedURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DashScopeError.audioConversionFailed
        }
        return convertedURL
    }

    // MARK: - ASR Transcription

    /// Batch ASR: 音频文件 → DashScope qwen3-asr-flash REST API → 文字
    func transcribe(audioFileURL: URL) async throws -> String {
        guard let key = apiKey else {
            throw DashScopeError.noAPIKey
        }

        // 1. 转换为 16kHz mono WAV
        let convertedURL = try convertTo16kMono(fileURL: audioFileURL)
        defer {
            if convertedURL != audioFileURL {
                try? FileManager.default.removeItem(at: convertedURL)
            }
        }

        // 2. 读取并 base64 编码
        let audioData = try Data(contentsOf: convertedURL)
        let base64Audio = audioData.base64EncodedString()
        viLog("DashScope ASR: file=\(audioFileURL.lastPathComponent), size=\(audioData.count) bytes")

        // 3. 构建请求
        let url = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // 4. 构建 body
        var messages: [[String: Any]] = []
        if !corpusText.isEmpty {
            messages.append(["role": "system", "content": [["type": "text", "text": corpusText]]])
        }
        messages.append([
            "role": "user",
            "content": [["type": "audio", "audio": "data:audio/wav;base64,\(base64Audio)"]]
        ])

        let body: [String: Any] = [
            "model": "qwen3-asr-flash",
            "input": ["messages": messages],
            "parameters": ["asr_options": ["language_hints": ["zh", "en"]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 5. 发送请求
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DashScopeError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            viLog("DashScope ASR error: HTTP \(http.statusCode): \(detail.prefix(200))")
            throw DashScopeError.httpError(http.statusCode, detail)
        }

        // 6. 解析响应: output.choices[0].message.content[0].text
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [String: Any],
              let choices = output["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            viLog("DashScope ASR: failed to parse response: \(raw.prefix(200))")
            throw DashScopeError.parseFailed
        }

        viLog("DashScope ASR: result='\(text.prefix(40))' (\(text.count) chars)")
        return text
    }

    // MARK: - LLM Refine

    /// LLM Refine: 文字 → DashScope qwen-flash → 优化后文字
    /// 失败时静默返回原文
    func refine(text: String, style: RefineStyle = .default) async -> String {
        guard let key = apiKey else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        viLog("DashScope Refine: starting, style=\(style.rawValue), length=\(trimmed.count)")

        do {
            let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 8

            // 构建 system message = preamble + prompt + style rule
            var systemParts: [String] = []
            if !preamble.isEmpty { systemParts.append(preamble) }
            if !promptText.isEmpty { systemParts.append(promptText) }
            if style != .default, let rule = styleRules[style.rawValue] {
                systemParts.append(rule)
            }
            let systemMessage = systemParts.joined(separator: "\n\n")

            // user message 用 XML delimiter 包裹
            let userMessage = "<transcription>\n\(trimmed)\n</transcription>"

            let body: [String: Any] = [
                "model": "qwen-flash",
                "temperature": 0.2,
                "max_tokens": 500,
                "messages": [
                    ["role": "system", "content": systemMessage],
                    ["role": "user", "content": userMessage]
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                viLog("DashScope Refine: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return text
            }

            // 解析 OpenAI 兼容格式: choices[0].message.content
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.isEmpty else {
                viLog("DashScope Refine: failed to parse response")
                return text
            }

            let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)

            // 长度卫士：输出 > 输入 3 倍则回退
            if refined.count > trimmed.count * 3 {
                viLog("DashScope Refine: output too long (\(refined.count) vs \(trimmed.count)), falling back")
                return text
            }

            viLog("DashScope Refine: done, \(trimmed.count)→\(refined.count) chars")
            return refined

        } catch {
            viLog("DashScope Refine: error \(error.localizedDescription), returning original")
            return text
        }
    }
}
