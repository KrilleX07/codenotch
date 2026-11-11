import Foundation

enum AntigravityHeadlineLimit: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case weekly = "weekly"
    case fiveHour = "5h"
    
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.t("Automatic")
        case .weekly: return L10n.t("Weekly Limit")
        case .fiveHour: return L10n.t("5-Hour Limit")
        }
    }

    var explanation: String { title }
}
