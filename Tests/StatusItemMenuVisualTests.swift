import AppKit
import XCTest
@testable import Codenotch

/// Opt-in visual check of the actual AppKit status-item menu, rather than an
/// NSImageView or a separately drawn approximation of its provider rows.
@MainActor
final class StatusItemMenuVisualTests: XCTestCase {
    func testOpenedNativeMenu() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODENOTCH_MENU_VISUAL_OUTPUT"] else {
            throw XCTSkip("Opt-in check opens and captures native status-item menus")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = [
            snapshot(id: "claude", name: "Claude", glyph: .claude, used: 1),
            snapshot(id: "codex", name: "Codex", glyph: .openai, used: 0.23),
        ]
        let originalAppearance = NSApp.appearance
        controller.show()
        defer { controller.hide(); NSApp.appearance = originalAppearance }
        let item = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "item" }?.value as? NSStatusItem)
        let button = try XCTUnwrap(item.button)
        // Allow the status-item scene to establish its real menu bar position.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let examples = controller.snapshots
        for (group, readings) in [("examples", examples), ("all-glyphs", ProviderGlyph.allCases.map {
            snapshot(id: $0.rawValue, name: $0.rawValue, glyph: $0, used: 0.23)
        })] {
            controller.snapshots = readings
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let path = URL(fileURLWithPath: directory).appendingPathComponent("\(group)-\(name.rawValue).png").path
                // Remote native menus follow system appearance. The external
                // runner switches it for this check and restores it afterwards.
                try Data((name == .darkAqua ? "true" : "false").utf8)
                    .write(to: URL(fileURLWithPath: path + ".prepare"))
                let preparationDeadline = Date().addingTimeInterval(30)
                while !FileManager.default.fileExists(atPath: path + ".prepared"), Date() < preparationDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".prepared"))
                NSApp.appearance = NSAppearance(named: name)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let started = Date()
                let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        // The test host has no screen-recording grant. An external
                        // runner captures this actual open menu after the marker.
                        try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
                            .write(to: URL(fileURLWithPath: path + ".ready"))
                        if FileManager.default.fileExists(atPath: path) || Date().timeIntervalSince(started) > 30 {
                            timer.invalidate()
                            item.menu?.cancelTracking()
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                // Appearance changes can dismiss a native menu before the
                // capture runner has obtained its window. Reopen it if needed.
                repeat {
                    button.performClick(nil)
                    if !FileManager.default.fileExists(atPath: path) {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    }
                } while !FileManager.default.fileExists(atPath: path) && Date().timeIntervalSince(started) < 30
                timer.invalidate()
                XCTAssertTrue(FileManager.default.fileExists(atPath: path), "The native menu was not captured")
            }
        }
    }

    private func snapshot(id: String, name: String, glyph: ProviderGlyph, used: Double) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: name, glyph: glyph, fidelity: .official, status: .ok,
                         windows: [LimitWindow(id: "session", label: "Current session", usedFraction: used,
                                               resetsAt: Date().addingTimeInterval(3600), duration: 5 * 3600)],
                         headlineID: "session")
    }
}
