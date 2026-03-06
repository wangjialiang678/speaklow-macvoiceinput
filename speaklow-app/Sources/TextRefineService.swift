import Foundation

enum RefineStyle: String, CaseIterable, Identifiable {
    case `default` = "default"
    case business = "business"
    case chat = "chat"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return "通用"
        case .business: return "商务"
        case .chat: return "聊天"
        }
    }
}

struct TextRefineService {
    private static let refineURL = "http://localhost:18089/v1/refine"
    private static let timeout: TimeInterval = 8

    /// Refine ASR text via LLM. Returns original text on any failure.
    static func refine(text: String, style: RefineStyle = .default) async -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        viLog("TextRefine: starting, style=\(style.rawValue), length=\(text.count)")

        do {
            let body: [String: String] = ["text": text, "style": style.rawValue]
            let bodyData = try JSONSerialization.data(withJSONObject: body)

            var request = URLRequest(url: URL(string: refineURL)!)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                viLog("TextRefine: bad status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return text
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let refinedText = json["refined_text"] as? String,
                  !refinedText.isEmpty else {
                viLog("TextRefine: invalid response")
                return text
            }

            let fallback = json["fallback"] as? Bool ?? false
            if fallback {
                viLog("TextRefine: LLM fallback, error=\(json["error"] ?? "unknown")")
            }

            let durationMs = json["duration_ms"] as? Int ?? 0
            viLog("TextRefine: done in \(durationMs)ms, \(text.count)→\(refinedText.count) chars, fallback=\(fallback)")
            return refinedText

        } catch {
            viLog("TextRefine: error \(error.localizedDescription), returning original")
            return text
        }
    }
}
