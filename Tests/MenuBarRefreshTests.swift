import AppKit
import Combine
import XCTest
@testable import Codenotch

@MainActor
final class MenuBarRefreshTests: XCTestCase {
    private func reading(_ glyph: ProviderGlyph = .claude, used: Double = 0.2) -> ProviderSnapshot {
        ProviderSnapshot(id: glyph.rawValue, displayName: glyph.rawValue, glyph: glyph,
                         fidelity: .official, status: .ok,
                         windows: [LimitWindow(id: "session", label: "5-hour Limit", usedFraction: used,
                                               resetsAt: Date().addingTimeInterval(3600), duration: 5 * 3600)],
                         headlineID: "session")
    }

    func testEveryGlyphUsesTheExistingMarkInMenuHeadersRegardlessOfBarSettings() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = ProviderGlyph.allCases.map { reading($0) }
        let menu = NSMenu()
        for limits in [MenuBarLimits.off, MenuBarLimits(isOn: true, chosen: ["claude"])] {
            controller.limits = limits
            controller.rebuild(menu: menu, now: Date())
            for snapshot in controller.snapshots {
                let row = try XCTUnwrap(menu.items.first { ($0.representedObject as? String) == snapshot.id })
                let image = try XCTUnwrap(row.image, snapshot.glyph.rawValue)
                XCTAssertTrue(image.isTemplate)
                XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
                XCTAssertEqual(row.indentationLevel, 0)
                if #available(macOS 27.0, *) {
                    XCTAssertEqual(row.value(forKey: "preferredImageVisibility") as? Int, 1)
                }
                XCTAssertEqual(row.action, Selector(("refreshProvider:")))
                // Compare pixels with the same glyph, including Claude's sun
                // and Codex's .openai knot, rather than accepting any image.
                XCTAssertEqual(render(image).tiffRepresentation,
                               render(try XCTUnwrap(snapshot.glyph.image())).tiffRepresentation)
            }
            for command in menu.items where command.action != nil && command.representedObject == nil {
                if #available(macOS 27.0, *) {
                    // AppKit may supply a native symbol (e.g. Settings' gear).
                    // Preserve that policy instead of forcing provider marks.
                    XCTAssertEqual(command.value(forKey: "preferredImageVisibility") as? Int, 0)
                }
            }
        }
    }

    private func render(_ image: NSImage, scale: Int = 2) -> NSBitmapImageRep {
        let size = Int(image.size.width) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func testAllMarksRenderAtRetinaResolutionInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for glyph in ProviderGlyph.allCases {
                    guard let image = glyph.image() else { XCTFail("Missing \(glyph)"); continue }
                    let rep = render(image)
                    XCTAssertEqual(rep.pixelsWide, 32)
                    var ink = 0
                    for y in 0..<rep.pixelsHigh {
                        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                            ink += 1
                        }
                    }
                    XCTAssertGreaterThan(ink, 5, "\(glyph) has no mark in \(name)")
                    XCTAssertLessThan(ink, 32 * 32, "\(glyph) is a solid placeholder")
                }
            }
        }
    }

    func testMissingAssetsUseAnOutlineOrGracefullyOmitTheIcon() throws {
        XCTAssertNotNil(ProviderGlyph.claude.image(assetLookup: { _ in nil }))
        XCTAssertNotNil(ProviderGlyph.openai.image(assetLookup: { _ in nil }))
        XCTAssertNil(ProviderGlyph.devin.image(assetLookup: { _ in nil }))
        let malformed = NSImage(size: .zero)
        XCTAssertNil(ProviderGlyph.devin.image(assetLookup: { _ in malformed }))
    }

    func testNativeTemplateTintFollowsLightAndDarkAppearance() throws {
        var luminances: [CGFloat] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            view.appearance = try XCTUnwrap(NSAppearance(named: name))
            view.image = try XCTUnwrap(ProviderGlyph.openai.image())
            view.contentTintColor = .labelColor
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            var total: CGFloat = 0
            var count: CGFloat = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.5 else { continue }
                    total += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    count += 1
                }
            }
            XCTAssertGreaterThan(count, 0)
            luminances.append(total / max(count, 1))
        }
        XCTAssertLessThan(luminances[0], 0.3, "Light appearance needs dark ink")
        XCTAssertGreaterThan(luminances[1], 0.7, "Dark appearance needs light ink")
    }

    func testOpenMenuUpdatesExistingRowsWithoutLosingCommandsAndStopsUpdatingOnClose() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = [reading()]
        var requests = 0
        controller.onRefreshAll = { requests += 1 }
        let menu = NSMenu()
        controller.menuWillOpen(menu)
        XCTAssertEqual(requests, 1)
        let header = try XCTUnwrap(menu.items.first)
        let refresh = try XCTUnwrap(menu.items.first { $0.keyEquivalent == "r" })
        controller.snapshots = [reading(used: 0.8)]
        XCTAssertTrue(menu.items.first === header)
        XCTAssertTrue(menu.items.contains { $0 === refresh })
        XCTAssertTrue(header.title.contains("80%"), header.title)
        XCTAssertEqual(requests, 1, "A publication must not request another fetch")
        controller.menuDidClose(menu)
        controller.snapshots = [reading(used: 0.4)]
        XCTAssertTrue(header.title.contains("80%"))
        controller.menuWillOpen(menu)
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(menu.items[0].title.contains("40%"))
    }

    @MainActor
    private final class Source: UsageProvider {
        nonisolated let id = "source"
        nonisolated let displayName = "Source"
        nonisolated let glyph = ProviderGlyph.openai
        nonisolated let minimumBackgroundRefreshInterval: TimeInterval
        nonisolated let isVisibleWhenAbsent: Bool
        var calls = 0
        var used = 0.2
        var resetsAt = Date().addingTimeInterval(3600)
        var failure: UsageProviderError?
        var hold = false
        var pending: CheckedContinuation<Void, Never>?

        init(interval: TimeInterval = 0, visible: Bool = true) {
            minimumBackgroundRefreshInterval = interval
            isVisibleWhenAbsent = visible
        }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            calls += 1
            if hold { await withCheckedContinuation { pending = $0 } }
            if let failure { throw failure }
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok,
                                    windows: [LimitWindow(id: "session", label: "5-hour Limit", usedFraction: used,
                                                          resetsAt: resetsAt, duration: 5 * 3600)],
                                    headlineID: "session")
        }
        func release() { hold = false; pending?.resume(); pending = nil }
        nonisolated func signOut() async {}
    }

    private func store(_ source: Source, interval: TimeInterval = 10,
                       now: @escaping () -> Date = Date.init) -> UsageStore {
        let defaults = UserDefaults(suiteName: "MenuBarRefreshTests.\(UUID().uuidString)")!
        return UsageStore(providers: [source], refreshInterval: interval,
                          idleRefreshInterval: interval,
                          archive: UsageArchive(defaults: defaults), pollingNow: now)
    }

    func testDefaultsAndPerProviderCadenceWithManualRefreshBypass() async {
        let source = Source(interval: 60)
        var now = Date()
        let store = store(source, now: { now })
        XCTAssertEqual(store.refreshIntervalForTesting, 10)
        XCTAssertEqual(store.idleRefreshIntervalForTesting, 10)
        await store.refresh()
        now += 10
        await store.refresh(background: true)
        XCTAssertEqual(source.calls, 1)
        now += 50
        await store.refresh(background: true)
        XCTAssertEqual(source.calls, 2)
        await store.refresh()
        XCTAssertEqual(source.calls, 3, "Opening or manual refresh bypasses only the scheduled floor")
    }

    func testIdleBackgroundTimerActuallyFetchesAgainAndStartIsIdempotent() async throws {
        let source = Source()
        let store = store(source, interval: 0.05)
        store.start()
        store.start()
        defer { store.stop() }
        try await Task.sleep(nanoseconds: 260_000_000)
        XCTAssertGreaterThanOrEqual(source.calls, 3, "No monitor activity is needed for the shipped schedule")
    }

    func testResetBoundaryIsFetchedBeforeTheProviderBackgroundFloor() async {
        let source = Source(interval: 60)
        var now = Date()
        source.resetsAt = now.addingTimeInterval(5)
        let store = store(source, now: { now })
        await store.refresh()
        now += 10
        source.used = 0
        await store.refresh(background: true)
        XCTAssertEqual(source.calls, 2)
        XCTAssertEqual(store.snapshots[0].windows[0].usedFraction, 0)
        await store.refresh(background: true)
        XCTAssertEqual(source.calls, 2, "A reset requests one read, not a retry loop")
    }

    func testRateLimitWaitIsHonouredByScheduledAndExplicitRequests() async {
        let source = Source()
        var now = Date()
        let store = store(source, now: { now })
        await store.refresh()
        let previous = store.snapshots[0]
        source.failure = .rateLimited(retryAfter: 45)
        await store.refresh()
        source.failure = nil
        source.used = 0.8
        now += 10
        await store.refresh(background: true)
        await store.refresh()
        XCTAssertEqual(source.calls, 2)
        XCTAssertEqual(store.snapshots, [previous])
        now += 35
        await store.refresh()
        XCTAssertEqual(source.calls, 3)
        XCTAssertEqual(store.snapshots[0].windows[0].usedFraction, 0.8)
    }

    func testTemporaryFailureKeepsUsageAndResetEvenForAnOptionalProvider() async {
        let source = Source(visible: false)
        let store = store(source)
        await store.refresh()
        let previous = store.snapshots
        source.failure = .badResponse(status: 503)
        await store.refresh()
        XCTAssertEqual(store.snapshots, previous)
        source.failure = nil
        source.used = 0.7
        await store.refresh()
        XCTAssertEqual(store.snapshots[0].windows[0].usedFraction, 0.7)
    }

    func testMenuOpeningUsesSharedStateRetainsReadingAndCoalescesInFlightRequests() async throws {
        let source = Source()
        let store = store(source)
        await store.refresh()
        let controller = StatusItemController(onOpenSettings: {})
        let subscription = store.$snapshots.receive(on: DispatchQueue.main)
            .sink { controller.snapshots = $0 }
        defer { subscription.cancel(); source.release(); store.stop() }
        source.used = 0.9
        source.hold = true
        controller.snapshots = store.snapshots
        controller.onRefreshAll = { store.refreshNow() }
        let menu = NSMenu()
        controller.menuWillOpen(menu)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(source.calls, 2)
        XCTAssertTrue(menu.items[0].title.contains("20%"), "Keep the old reading while fetching")
        store.refreshNow()
        _ = store.refresh(providerID: source.id)
        await store.refresh(background: true)
        XCTAssertEqual(source.calls, 2)
        source.release()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(menu.items[0].title.contains("90%"), menu.items[0].title)
        XCTAssertEqual(controller.snapshots, store.snapshots)
        XCTAssertTrue(store.inFlightForTesting.isEmpty)
    }
}
