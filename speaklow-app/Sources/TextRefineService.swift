import Foundation

enum RefineMode: String, CaseIterable, Identifiable {
    case correct = "correct"
    case polish = "polish"
    case both = "both"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .correct: return "纠错"
        case .polish: return "润色"
        case .both: return "纠错+润色"
        }
    }
}

struct TextRefineService {
    private static let refineURL = "http://localhost:18089/v1/refine"
    private static let timeout: TimeInterval = 8

    /// Refine ASR text via LLM. Returns original text on any failure.
    static func refine(text: String, mode: RefineMode) async -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        viLog("TextRefine: starting, mode=\(mode.rawValue), length=\(text.count)")

        do {
            let body: [String: String] = ["text": text, "mode": mode.rawValue]
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
