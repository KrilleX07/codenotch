import Foundation

enum AntigravityHeadlineModel: String, CaseIterable, Identifiable {
    case all = "all"
    case gemini = "gemini"
    case argon = "argon"
    case thirdParty = "3p"
    
    var id: String { rawValue }
    
    var explanation: String {
        switch self {
        case .all: return L10n.t("All models")
        case .gemini: return L10n.t("Gemini Models")
        case .argon: return L10n.t("Gemini 4 Argon")
        case .thirdParty: return L10n.t("Claude and GPT models")
        }
    }
}
