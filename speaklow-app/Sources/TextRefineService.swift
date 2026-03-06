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
    /// Refine ASR text via DashScope LLM (direct, no bridge).
    /// Returns original text on any failure.
    static func refine(text: String, style: RefineStyle = .default) async -> String {
        return await DashScopeClient.shared.refine(text: text, style: style)
    }
}
