import XCTest
import AppKit
@testable import Codenotch

/// What the menu bar item says in place of its icon: each five-hour window as
/// its provider's mark, the share spent, and the time until it resets.
@MainActor
final class StatusItemSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)
    private let hour: TimeInterval = 3600
    private let minute: TimeInterval = 60

    private func claude(_ used: Double?, resetIn: TimeInterval?, id: String = "claude",
                        status: ProviderStatus = .ok) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: id == "claude" ? "Claude" : "Claude (work)", glyph: .claude,
            fidelity: .official, status: status,
            windows: [
                LimitWindow(id: "session", label: "Current session", usedFraction: used,
                            resetsAt: resetIn.map { now.addingTimeInterval($0) }, duration: 5 * hour),
                LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.31,
                            resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400),
            ],
            headlineID: "session", weeklyID: "weekly_all")
    }

    private func codex(_ used: Double, resetIn: TimeInterval,
                       length: TimeInterval = 5 * 3600) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official, status: .ok,
            windows: [
                LimitWindow(id: "primary", label: CodexUsage.label(windowSeconds: length, fallback: "primary"),
                            usedFraction: used, resetsAt: now.addingTimeInterval(resetIn), duration: length),
                LimitWindow(id: "secondary", label: "Weekly limit", usedFraction: 0.12,
                            resetsAt: now.addingTimeInterval(4 * 86400), duration: 7 * 86400),
            ],
            headlineID: "primary", weeklyID: "secondary")
    }

    private func other(_ id: String, glyph: ProviderGlyph, length: TimeInterval,
                       kind: ProviderKind = .usage) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: id, glyph: glyph, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "main", label: "Limit", usedFraction: 0.5,
                                  resetsAt: now.addingTimeInterval(hour), duration: length)],
            headlineID: "main", kind: kind)
    }

    private func waiting(_ id: String, _ name: String, glyph: ProviderGlyph,
                         status: ProviderStatus = .stale(since: .distantPast)) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: name, glyph: glyph, fidelity: .official,
                         status: status, windows: [])
    }

    private func summary(_ snapshots: [ProviderSnapshot]) -> StatusItemSummary {
        StatusItemSummary.make(from: snapshots, now: now)
    }

    // MARK: - Which providers

    func testClaudeReadsAsItsSessionShareAndCountdown() throws {
        let entry = try XCTUnwrap(summary([claude(0.72, resetIn: 2 * hour + 18 * minute + 20)]).entries.first)
        XCTAssertEqual(entry.glyph, .claude)
        XCTAssertEqual(entry.percent, "72%")
        XCTAssertEqual(entry.countdown, "2h 18m")
        XCTAssertNil(entry.label)
        XCTAssertFalse(entry.isStale)
        XCTAssertEqual(entry.detail, "Claude — Current session: 72% Used · 28% left · 2h 18m")
    }

    func testCodexReadsItsFiveHourPrimaryWindow() throws {
        let entry = try XCTUnwrap(summary([codex(0.41, resetIn: 4 * hour + 5 * minute + 30)]).entries.first)
        XCTAssertEqual(entry.glyph, .openai)
        XCTAssertEqual(entry.percent, "41%")
        XCTAssertEqual(entry.countdown, "4h 05m")
    }

    /// Both, in the order the store keeps — which is the user's order, the
    /// same the notch draws its rings in.
    func testSeveralProvidersKeepTheStoresOrder() {
        let both = summary([codex(0.41, resetIn: 4 * hour), claude(0.72, resetIn: 2 * hour)])
        XCTAssertEqual(both.entries.map(\.id), ["codex", "claude"])
        XCTAssertFalse(both.isCompact)
    }

    /// The daily pace ring takes Claude's headline; the bar still means the
    /// five-hour session.
    func testTheDailyPaceRingDoesNotTakeTheSessionsPlace() throws {
        let paced = DailyPace.apply(to: claude(0.72, resetIn: 2 * hour), now: now)
        XCTAssertEqual(paced.headlineID, DailyPace.windowID)
        XCTAssertEqual(try XCTUnwrap(summary([paced]).entries.first).percent, "72%")
    }

    /// A monthly figure in the five-hour slot would be a different fact in
    /// the same clothes, and a local model has no quota at all.
    func testOnlyFiveHourWindowsAreSummarised() {
        let result = summary([
            other("cursor", glyph: .cursor, length: 30 * 86400),
            other("glm", glyph: .glm, length: 5 * hour),
            other("ollama-local", glyph: .ollamaLocal, length: 5 * hour, kind: .localRuntime),
        ])
        XCTAssertEqual(result.entries.map(\.id), ["glm"])
        XCTAssertTrue(summary([other("cursor", glyph: .cursor, length: 30 * 86400)]).entries.isEmpty,
                      "with nothing to summarise the item goes back to its icon")
    }

    /// Spark's five hours are Spark's, not the account's: with Codex's own
    /// window missing the bar shows a dash rather than Spark's figure. A
    /// grouped window the provider chose as its headline — an Antigravity
    /// model's — is still read.
    func testAGroupedWindowNeverStandsInForTheAccount() throws {
        var codex = codex(0.41, resetIn: 4 * hour)
        codex.windows = [LimitWindow(id: "spark", group: "Spark", label: "5h limit", usedFraction: 0.9,
                                     resetsAt: now.addingTimeInterval(hour), duration: 5 * hour)]
        XCTAssertTrue(try XCTUnwrap(summary([codex]).entries.first).isBlank)

        let antigravity = ProviderSnapshot(
            id: "gemini", displayName: "Antigravity", glyph: .antigravity, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "gemini-hourly", group: "Gemini Models", label: "5-hour Limit",
                                  usedFraction: 0.25, resetsAt: now.addingTimeInterval(hour), duration: 5 * hour)],
            headlineID: "gemini-hourly")
        XCTAssertEqual(try XCTUnwrap(summary([antigravity]).entries.first).percent, "25%")
    }

    /// Found by length, with room for a window sent as a start and an end.
    func testTheFiveHourWindowIsFoundByItsLength() {
        func window(_ length: TimeInterval?) -> LimitWindow {
            LimitWindow(id: "w", label: "W", usedFraction: 0.1, duration: length)
        }
        XCTAssertTrue(window(5 * hour).isFiveHour)
        XCTAssertTrue(window(5 * hour - 0.4).isFiveHour)
        XCTAssertFalse(window(4 * hour).isFiveHour)
        XCTAssertFalse(window(7 * 86400).isFiveHour)
        XCTAssertFalse(window(nil).isFiveHour)
    }

    /// Claude and Codex keep their place before the first reading and while
    /// signed out — with a dash, never a figure nobody measured.
    func testClaudeAndCodexShowADashWhileThereIsNoReading() {
        let result = summary([
            waiting("claude", "Claude", glyph: .claude, status: .needsAuth),
            waiting("codex", "Codex", glyph: .openai),
            waiting("cursor", "Cursor", glyph: .cursor),
        ])
        XCTAssertEqual(result.entries.map(\.id), ["claude", "codex"])
        for entry in result.entries {
            XCTAssertEqual(entry.percent, "—")
            XCTAssertEqual(entry.countdown, "—")
            XCTAssertTrue(entry.isBlank)
            XCTAssertFalse(entry.isStale, "a dash is not a reading to dim")
        }
        XCTAssertEqual(result.entries[0].detail, "Claude — Sign in to Claude Code to read your usage")
        XCTAssertEqual(result.entries[1].detail, "Codex — Waiting for the first reading…")
        XCTAssertNil(result.nextChange)
    }

    /// A free Codex plan meters thirty days, not five hours: the bar has no
    /// figure for it, and the tooltip says what the account does meter.
    func testAnAccountWithoutAFiveHourWindowSaysWhatItMetersInstead() throws {
        let entry = try XCTUnwrap(summary([codex(0.12, resetIn: 20 * 86400, length: 30 * 86400)]).entries.first)
        XCTAssertTrue(entry.isBlank)
        XCTAssertTrue(entry.detail.hasPrefix("Codex — Monthly limit: 12% Used"), entry.detail)
    }

    // MARK: - What each figure says

    func testPercentagesAreWholeAndNeverRoundToAFigureThatDidNotHappen() {
        let cases: [(Double, String)] = [
            (0, "0"), (0.003, "<1"), (0.07, "7"), (0.42, "42"), (0.72, "72"),
            (0.996, "99"), (1.0, "100"), (1.04, "104"), (-0.01, "0"),
        ]
        for (fraction, expected) in cases {
            XCTAssertEqual(Percent.whole(for: fraction), expected, "\(fraction)")
        }
    }

    func testASpentWindowReadsAsTheLimit() throws {
        XCTAssertEqual(try XCTUnwrap(summary([claude(1.0, resetIn: hour)]).entries.first).percent, "100%")
        XCTAssertEqual(try XCTUnwrap(summary([claude(1.04, resetIn: hour)]).entries.first).percent, "104%")
    }

    func testAnUnknownResetLeavesADashWhereTheCountdownWouldBe() throws {
        let result = summary([claude(0.72, resetIn: nil)])
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.percent, "72%")
        XCTAssertEqual(entry.countdown, "—")
        XCTAssertNil(result.nextChange, "nothing is counting down, so nothing needs to wake")
    }

    /// Past the reset the old share belongs to a window that is over. The
    /// store re-reads on its next tick; until then there is no figure.
    func testAPassedResetShowsNoFigureUntilTheNextReading() throws {
        let result = summary([claude(0.93, resetIn: -20)])
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.percent, "—")
        XCTAssertEqual(entry.countdown, "—")
        XCTAssertEqual(entry.detail, "Claude — Current session: Resetting…")
        XCTAssertNil(result.nextChange)
    }

    func testTheCountdownRunsDownToUnderAMinute() throws {
        XCTAssertEqual(try XCTUnwrap(summary([claude(0.66, resetIn: 47 * minute + 50)]).entries.first).countdown, "47m")
        XCTAssertEqual(try XCTUnwrap(summary([claude(0.93, resetIn: 42)]).entries.first).countdown, "<1m")
    }

    /// A remembered reading is dimmed, as the notch dims its ring, and says
    /// how old it is.
    func testARememberedReadingIsDimmedAndAged() throws {
        let stale = claude(0.72, resetIn: 2 * hour, status: .stale(since: now.addingTimeInterval(-40 * minute)))
        let entry = try XCTUnwrap(summary([stale]).entries.first)
        XCTAssertTrue(entry.isStale)
        XCTAssertEqual(entry.percent, "72%")
        XCTAssertTrue(entry.detail.hasSuffix("· 40 min ago"), entry.detail)
    }

    /// The minute the item next needs redrawing: the earliest of its countdowns.
    func testTheNextChangeIsTheEarliestCountdownMinute() {
        let result = summary([claude(0.72, resetIn: 2 * hour + 18 * minute + 20),
                              codex(0.41, resetIn: 4 * hour + 5 * minute + 30)])
        XCTAssertEqual(result.nextChange, now.addingTimeInterval(20))
    }

    // MARK: - Room in the bar

    /// Two Claude logins are two identical marks; the second says which it is.
    func testProfilesWithTheSameMarkAreToldApartBySlug() {
        let result = summary([claude(0.72, resetIn: 2 * hour), claude(0.12, resetIn: 4 * hour, id: "claude-work")])
        XCTAssertEqual(result.entries.map(\.label), [nil, "work"])
    }

    /// Past two, the countdowns stay in the tooltip; past four, in the menu.
    func testTheBarGoesCompactPastTwoAndStopsAtFour() {
        let many = [claude(0.72, resetIn: hour), codex(0.41, resetIn: hour),
                    other("glm", glyph: .glm, length: 5 * hour), other("kimi", glyph: .kimi, length: 5 * hour),
                    other("opencode", glyph: .opencode, length: 5 * hour)]
        let result = summary(many)
        XCTAssertEqual(result.entries.map(\.id), ["claude", "codex", "glm", "kimi"])
        XCTAssertTrue(result.isCompact)
        XCTAssertFalse(summary(Array(many.prefix(2))).isCompact)
    }

    /// The items to the left of this one shift whenever it changes width, so
    /// it keeps one width through the ordinary run of a window: single-digit
    /// shares, the last hour, the last minute, an unknown reset.
    func testTheItemKeepsOneWidthAsTheFiguresMove() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        func width(_ used: Double, _ resetIn: TimeInterval?) -> CGFloat {
            StatusItemArtwork(summary: summary([claude(used, resetIn: resetIn)]), font: font, height: 22).size.width
        }
        let reference = width(0.72, 2 * hour + 18 * minute)
        for (used, resetIn) in [(0.07, 2 * hour + 18 * minute), (0.0, 4 * hour + 59 * minute),
                                (0.003, 3 * hour), (0.72, 47 * minute), (0.72, 8 * minute),
                                (0.72, 30), (0.72, nil)] as [(Double, TimeInterval?)] {
            XCTAssertEqual(width(used, resetIn), reference, "\(used) with \(String(describing: resetIn))s left")
        }
        XCTAssertLessThan(width(0.72, nil), 150, "one reading should stay compact")
    }

    /// A template, as the icon it stands in for is, so macOS tints it for
    /// light, dark and wallpaper-tinted menu bars alike.
    func testTheArtworkIsATemplateTheHeightOfTheBar() {
        let artwork = StatusItemArtwork(summary: summary([claude(0.72, resetIn: hour)]),
                                        font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                                        height: 22)
        let image = artwork.image()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.height, 22)
        XCTAssertGreaterThan(image.size.width, 0)
    }
}
