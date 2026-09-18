import AppKit
import XCTest
@testable import Codenotch

@MainActor
final class MenuBarResetDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)
    private let english = Locale(identifier: "en_US")

    func testCompactAndDetailedCountdownBoundaries() {
        let cases: [(TimeInterval, String)] = [
            (1, "<1m"), (59.9, "<1m"), (60, "1m"), (42 * 60 + 59, "42m"),
            (3600, "1h 00m"), (3 * 3600 + 21 * 60, "3h 21m"),
            (86400 - 1, "23h 59m"), (86400, "1d 0h"),
            (2 * 86400 + 4 * 3600 + 59 * 60, "2d 4h"), (26 * 86400, "26d 0h")
        ]
        for (seconds, expected) in cases {
            let reset = now.addingTimeInterval(seconds)
            XCTAssertEqual(ResetCopy.menuBarText(for: reset, now: now, format: .remaining,
                                                context: .compact, locale: english), expected)
            XCTAssertEqual(ResetCopy.menuBarText(for: reset, now: now, format: .remaining,
                                                context: .detail, locale: english), "Resets in \(expected)")
        }
    }

    func testDateDetailPreservesExistingCopyExactly() {
        let intervals: [TimeInterval] = [-1, 0, 1, 3040, 3580, 3600, 259200, 604800, 2246400]
        for seconds in intervals {
            let reset = now.addingTimeInterval(seconds)
            XCTAssertEqual(ResetCopy.menuBarText(for: reset, now: now, context: .detail, locale: english),
                           ResetCopy.text(for: reset, now: now, locale: english))
        }
    }

    func testMissingInvalidAndPassedDatesDoNotProduceNegativeOrInvalidCopy() {
        for reset: Date? in [nil, Date(timeIntervalSinceReferenceDate: .nan),
                            Date(timeIntervalSinceReferenceDate: .infinity),
                            Date(timeIntervalSinceReferenceDate: -.infinity),
                            Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude)] {
            for mode in ResetTimeFormat.allCases {
                XCTAssertNil(ResetCopy.menuBarText(for: reset, now: now, format: mode, context: .compact))
                XCTAssertNil(ResetCopy.menuBarText(for: reset, now: now, format: mode, context: .detail))
            }
            if let reset {
                XCTAssertNil(ResetCopy.countdown(to: reset, now: now))
                XCTAssertNil(ResetCopy.nextCountdownChange(to: reset, now: now))
            }
        }
        for mode in ResetTimeFormat.allCases {
            XCTAssertNil(ResetCopy.menuBarText(for: now, now: now, format: mode, context: .compact))
            XCTAssertEqual(ResetCopy.menuBarText(for: now.addingTimeInterval(-1), now: now,
                                                format: mode, context: .detail), "Resetting…")
        }
    }

    func testMenuBarPreferenceDefaultsPersistsAndIsIndependentOfNotch() throws {
        let domain = "MenuBarResetDisplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertEqual(Preferences(defaults: defaults).menuBarResetTimeFormat, .automatic)
        defaults.set("remaining", forKey: "resetTimeFormat")
        let upgraded = Preferences(defaults: defaults)
        XCTAssertEqual(upgraded.menuBarResetTimeFormat, .automatic)
        XCTAssertEqual(upgraded.resetTimeFormat, .remaining)
        upgraded.menuBarResetTimeFormat = .remaining
        defaults.synchronize()
        XCTAssertEqual(Preferences(defaults: UserDefaults(suiteName: domain)!).menuBarResetTimeFormat, .remaining)
        upgraded.menuBarResetTimeFormat = .automatic
        XCTAssertEqual(Preferences(defaults: defaults).menuBarResetTimeFormat, .automatic)
        XCTAssertEqual(upgraded.resetTimeFormat, .remaining)
        defaults.set("unknown", forKey: "menuBarResetTimeFormat")
        XCTAssertEqual(Preferences(defaults: defaults).menuBarResetTimeFormat, .automatic)
    }

    func testDefaultTopBarUsesSharedDateValueAndRemainingUsesCountdown() throws {
        let snapshot = reading(reset: now.addingTimeInterval(3 * 3600 + 21 * 60))
        let limits = MenuBarLimits(isOn: true, chosen: [snapshot.id])
        let date = StatusItemSummary.make(from: [snapshot], showing: limits, now: now)
        XCTAssertEqual(try XCTUnwrap(date.entries.first).resetText,
                       ResetCopy.menuBarText(for: snapshot.windows[0].resetsAt, now: now, context: .compact))
        XCTAssertEqual(date.nextChange, snapshot.windows[0].resetsAt)
        let relative = StatusItemSummary.make(from: [snapshot], showing: limits, now: now, format: .remaining)
        XCTAssertEqual(try XCTUnwrap(relative.entries.first).resetText, "3h 21m")
        XCTAssertEqual(date.entries.first?.percent, relative.entries.first?.percent)
        XCTAssertEqual(date.entries.first?.glyph, relative.entries.first?.glyph)
    }

    func testEveryProviderGlyphAndWindowUsesTheSameResetPresentation() {
        for glyph in ProviderGlyph.allCases {
            let snapshot = reading(glyph: glyph, reset: now.addingTimeInterval(3 * 3600 + 21 * 60))
            let dateLines = StatusItemController.detailLines(for: snapshot, now: now)
            for (line, window) in zip(dateLines, snapshot.windows) {
                XCTAssertEqual(line, "\(window.label): \(window.summary) · \(ResetCopy.text(for: window.resetsAt!, now: now))")
            }
            let relative = StatusItemController.detailLines(for: snapshot, now: now, format: .remaining)
            XCTAssertTrue(relative[0].hasSuffix("Resets in 3h 21m"), glyph.rawValue)
            XCTAssertTrue(relative[1].hasSuffix("Resets in 2d 4h"), glyph.rawValue)
        }
    }

    func testPreferenceChangesUpdateOpenMenuImmediatelyWithoutRequests() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = [reading(reset: Date().addingTimeInterval(3 * 3600 + 21 * 60 + 30))]
        var requests = 0
        controller.onRefreshAll = { requests += 1 }
        let menu = NSMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let row = menu.items[1]
        let original = row.title
        controller.resetTimeFormat = .remaining
        XCTAssertTrue(row.title.hasSuffix("Resets in 3h 21m"), row.title)
        XCTAssertTrue(menu.items[1] === row)
        controller.resetTimeFormat = .automatic
        XCTAssertEqual(row.title, original)
        XCTAssertEqual(requests, 1, "Only the existing menu-opening refresh is requested")
        XCTAssertNotNil(menu.items[0].image)
    }

    func testBlockedResetFollowsTheModeAndPreservesExistingDateCopy() {
        let reset = now.addingTimeInterval(3 * 3600 + 21 * 60)
        var snapshot = reading(reset: reset)
        snapshot.block = UsageBlock(reason: "Usage limit reached", resetsAt: reset)
        XCTAssertEqual(StatusItemController.detailLines(for: snapshot, now: now).first,
                       snapshot.block?.summary(now: now))
        XCTAssertEqual(StatusItemController.detailLines(for: snapshot, now: now, format: .remaining).first,
                       "Usage limit reached · Resets in 3h 21m")
    }

    func testNativeStatusButtonChangesImmediatelyAndCountsDownWithoutRequests() async throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.limits = MenuBarLimits(isOn: true, chosen: ["claude"])
        controller.snapshots = [reading(reset: Date().addingTimeInterval(3 * 3600 + 21 * 60 + 30))]
        var requests = 0
        controller.onRefreshAll = { requests += 1 }
        controller.onRefreshProvider = { _ in requests += 1 }
        controller.show()
        defer { controller.hide() }
        let item = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "item" }?.value as? NSStatusItem)
        let button = try XCTUnwrap(item.button)
        let original = button.toolTip
        XCTAssertFalse(original?.contains("3h 21m") ?? true)
        controller.resetTimeFormat = .remaining
        XCTAssertTrue(button.toolTip?.hasSuffix("3h 21m") ?? false)
        XCTAssertEqual(button.accessibilityLabel(), button.toolTip)
        controller.resetTimeFormat = .automatic
        XCTAssertEqual(button.toolTip, original)
        controller.resetTimeFormat = .remaining
        controller.snapshots = [reading(reset: Date().addingTimeInterval(61.5))]
        XCTAssertTrue(button.toolTip?.hasSuffix("1m") ?? false)
        try await Task.sleep(nanoseconds: 2_700_000_000)
        XCTAssertTrue(button.toolTip?.hasSuffix("<1m") ?? false)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(try XCTUnwrap(button.image).isTemplate)
    }

    func testLocalTimerUpdatesOpenIconOnlyMenuAndNewSnapshotsWithoutRequests() async throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.resetTimeFormat = .remaining
        controller.snapshots = [reading(reset: Date().addingTimeInterval(61.5))]
        var requests = 0
        controller.onRefreshAll = { requests += 1 }
        let menu = NSMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let row = menu.items[1]
        XCTAssertTrue(row.title.hasSuffix("Resets in 1m"), row.title)
        try await Task.sleep(nanoseconds: 2_700_000_000)
        XCTAssertTrue(row.title.hasSuffix("Resets in <1m"), row.title)
        XCTAssertEqual(requests, 1)
        controller.snapshots = [reading(reset: Date().addingTimeInterval(3 * 3600 + 21 * 60 + 30))]
        XCTAssertTrue(row.title.hasSuffix("Resets in 3h 21m"), row.title)
        XCTAssertEqual(requests, 1)
        controller.snapshots = [reading(reset: Date().addingTimeInterval(0.4))]
        try await Task.sleep(nanoseconds: 1_700_000_000)
        XCTAssertTrue(row.title.hasSuffix("Resetting…"), row.title)
        XCTAssertEqual(requests, 1, "Expiry uses the store's existing refresh behaviour")
    }

    private func reading(glyph: ProviderGlyph = .claude, reset: Date) -> ProviderSnapshot {
        ProviderSnapshot(id: glyph.rawValue, displayName: glyph.rawValue, glyph: glyph,
                         fidelity: .official, status: .ok,
                         windows: [LimitWindow(id: "session", label: "Current session", usedFraction: 0.65,
                                               resetsAt: reset, duration: 5 * 3600),
                                   LimitWindow(id: "weekly", label: "Weekly limit", usedFraction: 0.71,
                                               resetsAt: now.addingTimeInterval(2 * 86400 + 4 * 3600),
                                               duration: 7 * 86400)], headlineID: "session", weeklyID: "weekly")
    }
}
