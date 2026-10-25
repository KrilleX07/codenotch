import SwiftUI

/// The direction and fill style of the horizontal progress bar in hover cards.
enum ProgressBarMode: String, CaseIterable, Identifiable {
    /// Classic: fills from left to right as quota is consumed (0% → 100%).
    case consumed
    /// Draining: starts full and empties from right to left as quota is consumed (100% → 0%).
    case remaining

    var id: String { rawValue }

    var title: String {
        switch self {
        case .consumed: return L10n.t("Consumed")
        case .remaining: return L10n.t("Remaining")
        }
    }

    var explanation: String {
        switch self {
        case .consumed:
            return L10n.t("Bar fills from left to right (0% to 100%) as quota is used.")
        case .remaining:
            return L10n.t("Bar starts full and empties from right to left (100% to 0%) as quota is used.")
        }
    }
}

private struct ProgressBarModeKey: EnvironmentKey {
    static let defaultValue = ProgressBarMode.consumed
}

extension EnvironmentValues {
    var progressBarMode: ProgressBarMode {
        get { self[ProgressBarModeKey.self] }
        set { self[ProgressBarModeKey.self] = newValue }
    }
}
