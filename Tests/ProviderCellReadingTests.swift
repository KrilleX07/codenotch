import XCTest
@testable import Codenotch

@MainActor
final class ProviderCellReadingTests: XCTestCase {
    private let snapshot = ProviderSnapshot(
        id: "claude", displayName: "Claude", glyph: .claude,
        fidelity: .official, status: .ok,
        windows: [
            LimitWindow(id: "session", label: "5-hour limit", usedFraction: 0.30, resetsAt: nil),
            LimitWindow(id: "weekly", label: "Weekly limit", usedFraction: 0.70, resetsAt: nil),
        ],
        headlineID: "session", weeklyID: "weekly"
    )

    private func reading(_ weeklyRing: WeeklyRing, weekly: Bool) -> String {
        ProviderCell(snapshot: snapshot, weeklyRing: weeklyRing, showsWeeklyReading: weekly).accessibilityText
    }

    func testTheWeeklyPercentageFollowsTheSession() {
        XCTAssertEqual(reading(.outside, weekly: true), "Claude, 30%/70%")
    }

    /// The ring can be on without its number, and the number never shows
    /// without the ring it belongs to.
    func testItNeedsBothTheSettingAndTheRing() {
        XCTAssertEqual(reading(.outside, weekly: false), "Claude, 30%")
        XCTAssertEqual(reading(.off, weekly: true), "Claude, 30%")
    }
}
