import XCTest
import SwiftUI
@testable import Codenotch

/// **One silhouette, not two shapes that touch.**
///
/// Placed beside the display's own hole the notch used to be a second black
/// object a few points away from the first, and that is not what the machine
/// looks like: the eye finds the gap and reads a mistake. So the notch now
/// starts *inside* the hole and flows out of it — the leading end loses its
/// flare, holds the hole's own depth as far as the hole's wall, and steps down
/// onto the bar's far side with no bend at either join.
///
/// Every test here measures the drawn path in screen points, because that is
/// the only space in which "does it line up with the hole" is a question. The
/// mapping is the view's own: the shape is drawn in design points, scaled by
/// the size setting from the bezel, pushed `bezelBleed` past it, and laid into
/// the panel at `notchAlongLead`.
@MainActor
final class MergesWithTheCutoutTests: XCTestCase {
    private struct Notched: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var visibleFrameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var hardwareNotch: HardwareNotch? { HardwareNotch(width: 220, height: 38) }
        var displayIdentifier: String? { nil }
    }
    private struct Plain: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var visibleFrameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var displayIdentifier: String? { nil }
    }

    private func model(_ screen: ScreenDescribing, scale: CGFloat = 1,
                       open: Bool = true, offset: CGFloat = 0) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.sizeScale = scale
        m.alongOffset = offset
        m.snapshots = (0..<3).map {
            ProviderSnapshot(id: "p\($0)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        m.adopt(screen: screen)
        m.isExpanded = open
        return m
    }

    /// A point on the drawn outline: how far right of the screen's left edge,
    /// and how far *below the top of the screen* — which is the axis the hole is
    /// measured on too.
    private struct Sample {
        var x: CGFloat
        var depth: CGFloat
    }

    /// The whole outline, in screen points.
    ///
    /// Flattened rather than read element by element: the bridge is a polyline
    /// and the flares are too, but the corners are cubics, and a control point
    /// is not a point on the curve. Sampling each one means "nothing of this
    /// shape hangs below the hole" can be asked of the shape itself rather than
    /// of the parts of it that happen to be straight.
    private func outline(of m: NotchViewModel, on screen: ScreenDescribing) -> [Sample] {
        let frame = NotchGeometry.panelFrame(
            for: screen, panelSize: m.panelSize, edge: m.edge,
            alongOffset: m.alongOffset, slack: m.slack,
            trailingExtent: m.trailingExtent, leadingExtent: m.leadingExtent
        )
        var samples: [Sample] = []
        // Every drawn copy, as the shape it is drawn as — the one on the left
        // of the hole is reflected in its own path, not flipped by the view.
        for wing in m.wings where wing.length > 0 {
            let size = NotchPlacement.panelSize(edge: .top,
                                                length: wing.length / m.sizeScale,
                                                depth: wing.depth)
            let path = m.notchShape(for: wing).path(in: CGRect(origin: .zero, size: size))
            let lead = frame.minX + wing.lead
            let place = { (p: CGPoint) in
                Sample(x: lead + p.x * m.sizeScale,
                       depth: p.y * m.sizeScale - NotchRootView.bezelBleed)
            }
            samples += walk(path, place)
        }
        return samples
    }

    private func walk(_ path: Path, _ place: (CGPoint) -> Sample) -> [Sample] {
        var samples: [Sample] = []
        var cursor = CGPoint.zero
        var start = CGPoint.zero
        func cubic(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint) {
            for i in 1...16 {
                let t = CGFloat(i) / 16, u = 1 - t
                let w = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
                samples.append(place(CGPoint(
                    x: w.0 * a.x + w.1 * c1.x + w.2 * c2.x + w.3 * b.x,
                    y: w.0 * a.y + w.1 * c1.y + w.2 * c2.y + w.3 * b.y)))
            }
        }
        path.forEach { element in
            switch element {
            case .move(let to):
                start = to
                cursor = to
                samples.append(place(to))
            case .line(let to):
                // Along the line, not only at its ends: the joined end's bottom
                // edge is one straight run from inside the hole out past its
                // wall, and "what is at the wall" has to find a point there.
                let steps = max(1, Int((hypot(to.x - cursor.x, to.y - cursor.y)).rounded(.up)))
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    samples.append(place(CGPoint(x: cursor.x + (to.x - cursor.x) * t,
                                                 y: cursor.y + (to.y - cursor.y) * t)))
                }
                cursor = to
            case .quadCurve(let to, let control):
                cubic(cursor,
                      CGPoint(x: cursor.x + 2.0 / 3 * (control.x - cursor.x),
                              y: cursor.y + 2.0 / 3 * (control.y - cursor.y)),
                      CGPoint(x: to.x + 2.0 / 3 * (control.x - to.x),
                              y: to.y + 2.0 / 3 * (control.y - to.y)),
                      to)
                cursor = to
            case .curve(let to, let control1, let control2):
                cubic(cursor, control1, control2, to)
                cursor = to
            case .closeSubpath:
                cursor = start
            }
        }
        return samples
    }

    /// Where the hole's trailing wall stands, and how deep the hole is.
    /// The nudge that puts the notch on the left of the hole, flush against its
    /// left wall — the far end of the run the nudge travels.
    private func flushOnTheLeft(_ screen: ScreenDescribing) throws -> CGFloat {
        _ = try XCTUnwrap(screen.hardwareNotch)
        return -2 * NotchGeometry.cutoutTravel
    }

    private func hole(_ screen: ScreenDescribing) throws
    -> (wall: CGFloat, left: CGFloat, depth: CGFloat) {
        let cutout = try XCTUnwrap(screen.hardwareNotch)
        return (screen.frameValue.midX + cutout.width / 2,
                screen.frameValue.midX - cutout.width / 2,
                cutout.height)
    }

    // MARK: - The join

    /// **Nothing of the notch hangs out below the hole.**
    ///
    /// This is the one that has to hold, open or folded, at every size. The
    /// overlap is drawn at the hole's own depth so that it fills the lit sliver
    /// in the crook of the hole's rounded corner — a point deeper than that, in
    /// the stretch left of the wall, is a black tongue poking out from under the
    /// hardware's notch where there is nothing for it to belong to.
    func testNothingIsDrawnBelowTheHoleInsideIt() throws {
        for scale in [0.5, 1.0, 1.5] as [CGFloat] {
            for open in [true, false] {
                let screen = Notched()
                let m = model(screen, scale: scale, open: open)
                let hole = try hole(screen)
                let inside = outline(of: m, on: screen).filter { $0.x < hole.wall - 0.5 }
                XCTAssertFalse(inside.isEmpty,
                               "scale \(scale) open \(open): nothing overlaps the hole at all, "
                               + "so there is no join — only two shapes side by side")
                let deepest = inside.map(\.depth).max() ?? 0
                XCTAssertLessThanOrEqual(deepest, hole.depth + 0.6,
                                         "scale \(scale) open \(open): the notch reaches "
                                         + "\(deepest)pt below the screen's top inside the "
                                         + "hole, which is only \(hole.depth)pt deep — that "
                                         + "much of it is drawn on the wallpaper")
            }
        }
    }

    /// **And it is flush with the hole where it meets it**, rather than stopping
    /// short of its bottom edge and leaving a step.
    func testItMeetsTheHolesBottomEdgeExactly() throws {
        for open in [true, false] {
            let screen = Notched()
            let m = model(screen, open: open)
            let hole = try hole(screen)
            let atWall = outline(of: m, on: screen)
                .filter { abs($0.x - hole.wall) < 1.5 }
                .map(\.depth)
            XCTAssertFalse(atWall.isEmpty, "open \(open): the outline never reaches the wall")
            XCTAssertEqual(atWall.max() ?? 0, hole.depth, accuracy: 0.8,
                           "open \(open): at the hole's wall the notch is "
                           + "\(atWall.max() ?? 0)pt deep against the hole's \(hole.depth) — "
                           + "a step, and a step is a seam")
        }
    }

    /// **No crease at either end of the bridge.**
    ///
    /// The bridge leaves the hole's bottom edge and lands on the bar's far side,
    /// and both of those are straight. A curve that arrives at an angle puts a
    /// crease there, and a crease is exactly where the eye stops reading one
    /// object and starts reading two — which is the whole complaint the flare
    /// was rebuilt for once already.
    func testTheBridgeLeavesAndLandsFlat() throws {
        let screen = Notched()
        let m = model(screen)
        let hole = try hole(screen)
        let bar = m.notchDepth * m.sizeScale - NotchRootView.bezelBleed

        // The leading end only. Filtered by depth alone this picks up the far
        // corner and the trailing flare as well, which span the same band — and
        // then "where the bridge lands" is measured at the other end of the bar.
        let end = hole.wall + m.flare * m.sizeScale + 2
        let bridge = outline(of: m, on: screen)
            .filter { $0.x >= hole.wall - 0.5 && $0.x <= end }
            .filter { $0.depth >= hole.depth - 1 && $0.depth <= bar + 1 }
            .sorted { $0.x < $1.x }
        guard bridge.count > 8 else {
            return XCTFail("the bridge is too coarse to measure")
        }

        func slope(_ a: Sample, _ b: Sample) -> CGFloat {
            guard b.x - a.x > 0.0001 else { return .greatestFiniteMagnitude }
            return abs(b.depth - a.depth) / (b.x - a.x)
        }
        // Over the first and last twelfth of it, where a curve that arrived at
        // an angle would have already turned.
        let step = max(1, bridge.count / 12)
        XCTAssertLessThan(slope(bridge[0], bridge[step]), 0.12,
                          "the bridge leaves the hole's bottom edge at an angle")
        XCTAssertLessThan(slope(bridge[bridge.count - 1 - step], bridge[bridge.count - 1]), 0.12,
                          "the bridge lands on the bar's far side at an angle")
    }

    /// **The leading end has no flare left.** A flare is how a shape says it
    /// begins here; this end does not begin, it continues.
    func testTheLeadingEndDoesNotTaperBackToTheBezel() {
        let merged = model(Notched())
        let plain = model(Plain())
        let near = CGFloat(4)   // just below the bezel

        func leadingEdge(_ m: NotchViewModel, _ screen: ScreenDescribing) -> CGFloat {
            let path = m.notchShape.path(in: CGRect(origin: .zero, size: m.notchSize))
            let place = NotchPlacement(edge: .top, panelSize: m.notchSize)
            return stride(from: CGFloat(0), to: m.notchSize.width, by: 0.5)
                .first { path.contains(place.point(along: $0, across: near)) } ?? .infinity
        }

        XCTAssertLessThan(leadingEdge(merged, Notched()), 1,
                          "the merged notch still tapers away from its leading tip")
        XCTAssertGreaterThan(leadingEdge(plain, Plain()), NotchLayout.curlRadius / 2,
                             "the plain notch should still flare back to the bezel")
    }

    // MARK: - Staying joined

    /// **Folding does not let go.**
    ///
    /// The notch normally shrinks toward its own centre line so that hiding
    /// does not slide it along the edge. Joined to the hole it has to shrink
    /// toward the *hole* instead: a pill that retreated to the middle of its
    /// panel would leave the bridge stretched across a hundred points of bezel.
    func testItFoldsTowardTheHoleRatherThanItsOwnCentre() throws {
        let m = model(Notched())
        func joinedEnds(_ m: NotchViewModel) -> [CGFloat] {
            let drawn = m.notchLength * m.sizeScale
            // The end of each copy that meets the hole: the far end of the one
            // on the left, the near end of the one on the right.
            return m.wings.map { $0.onTheLeft ? $0.lead + drawn : $0.lead }
        }
        let open = joinedEnds(m)
        XCTAssertEqual(open.count, 2, "joined, it is drawn either side of the hole")
        m.isExpanded = false
        for (was, now) in zip(open, joinedEnds(m)) {
            XCTAssertEqual(now, was, accuracy: 0.001, "a folded copy let go of the hole")
        }

        // And a notch with no hole to hold on to still contracts in place.
        let plain = model(Plain())
        let openCentre = plain.notchAlongLead + plain.notchLength * plain.sizeScale / 2
        plain.isExpanded = false
        XCTAssertEqual(plain.notchAlongLead + plain.notchLength * plain.sizeScale / 2,
                       openCentre, accuracy: 0.001,
                       "a notch with no hole should still fold to its own centre line")
    }

    /// **The copy that carries the readings is always identity 0**, whether it
    /// is a lone bar, in the hand, or one of a joined pair — and it is never
    /// flipped, because nothing is.
    ///
    /// The bar being dragged has to *be* the bar that lands, or the landing is
    /// one view vanishing and another appearing: a swap, not a movement. And
    /// nothing may be turned over by the view, because a view's `scaleEffect`
    /// is a number SwiftUI animates, and every time a copy's side changed under
    /// one identity the bar turned over through nothing on the way. The copy on
    /// the left of the hole is its own shape now, reflected in the path.
    func testTheCarryingCopyIsOneBarFromPickUpToLanding() {
        let plain = model(Plain())
        let joined = model(Notched())
        let onTheLeft = model(Notched(), offset: -2 * NotchGeometry.cutoutTravel)
        for m in [plain, joined, onTheLeft] {
            XCTAssertEqual(m.cellWing.id, 0, "the carrying copy changed identity")
            XCTAssertEqual(m.wings.filter(\.carriesCells).count, 1,
                           "exactly one copy carries the readings")
            XCTAssertEqual(Set(m.wings.map(\.id)).count, m.wings.count,
                           "two copies share an identity")
        }
        XCTAssertFalse(joined.cellWing.onTheLeft)
        XCTAssertTrue(onTheLeft.cellWing.onTheLeft,
                      "put down on the left, the readings should stay on the left")
        XCTAssertTrue(joined.handleWing.carriesCells, "the handles are on the empty copy")
    }

    /// **It is drawn on both sides of the hole**, mirrored, so the hardware's
    /// own notch reads as having the app either side of it rather than as
    /// something with a bar stuck to one edge.
    func testItIsDrawnEitherSideOfTheHole() throws {
        let screen = Notched()
        let m = model(screen)
        let hole = try hole(screen)
        XCTAssertEqual(m.wings.count, 2)
        XCTAssertEqual(m.wings.filter(\.onTheLeft).count, 1, "one of the pair is on each side")

        let frame = NotchGeometry.panelFrame(
            for: screen, panelSize: m.panelSize, edge: .top,
            alongOffset: m.alongOffset, slack: m.slack,
            trailingExtent: m.trailingExtent, leadingExtent: m.leadingExtent)
        let bar = m.shapeLength * m.sizeScale
        let left = frame.minX + (m.wings.first?.lead ?? 0)
        let right = frame.minX + (m.wings.last?.lead ?? 0) + bar
        XCTAssertEqual(hole.wall - right, left - hole.left, accuracy: 1.5,
                       "the two reach the same distance either side of the hole")

        // And a display with no hole gets one bar, as every other edge does.
        XCTAssertEqual(model(Plain()).wings.count, 1)
    }

    /// The buried overlap is length nobody sees, so the bar is drawn longer by
    /// exactly that much — otherwise the merged notch starts short of the wall
    /// and everything in it sits closer to its visible start than it should.
    func testTheBuriedOverlapIsPaidForInLength() {
        let merged = model(Notched())
        XCTAssertEqual(merged.cutoutBleed * merged.sizeScale,
                       NotchGeometry.cutoutOverlap, accuracy: 0.001)
        XCTAssertEqual(merged.cellsLeadIn - merged.cutoutBleed, model(Plain()).cellsLeadIn,
                       accuracy: 0.001, "the first ring moved relative to the visible start")
    }

    // MARK: - One thickness

    /// **It is exactly as deep as the hole**, at every size setting and in both
    /// states. One shape cannot be two thicknesses: drawn deeper it bulged out
    /// from under the hardware, drawn shallower it tapered up out of it, and the
    /// fold morphed between the two — which is what "looks like a glitch" was.
    func testItIsExactlyAsDeepAsTheHole() throws {
        let screen = Notched()
        let hole = try hole(screen)
        for scale in [0.5, 0.589, 1.0, 1.5] as [CGFloat] {
            for open in [true, false] {
                let m = model(screen, scale: scale, open: open)
                let drawn = m.notchDepth * m.sizeScale - NotchRootView.bezelBleed
                XCTAssertEqual(drawn, hole.depth, accuracy: 0.001,
                               "scale \(scale) open \(open)")
            }
        }
    }

    /// And folding changes the length alone, so the fold is a bar drawing itself
    /// in along one axis rather than a shape changing into another shape.
    func testFoldingChangesOnlyTheLength() {
        let m = model(Notched())
        let open = m.notchDepth
        m.isExpanded = false
        XCTAssertEqual(m.notchDepth, open, accuracy: 0.001,
                       "the merged notch still changes depth as it folds")
        XCTAssertLessThan(m.notchLength, m.shapeLength, "it should still shorten")
    }

    /// **The bridge has no step left to make.** With both bottom edges at one
    /// depth the join is a straight line, which is the whole point of taking the
    /// hardware's depth: there is no waist to see because there is no mismatch.
    func testTheTwoBottomEdgesAreOneStraightLine() throws {
        let screen = Notched()
        let m = model(screen)
        let hole = try hole(screen)
        // From the wall outward — where it leaves the hole. Inside the hole is
        // the joined end's square tip, standing where nothing shows.
        let far = outline(of: m, on: screen)
            .filter { $0.x >= hole.wall - 0.5 && $0.x < hole.wall + m.flare * m.sizeScale }
            .map(\.depth)
            .filter { $0 > hole.depth / 2 }
        XCTAssertFalse(far.isEmpty)
        XCTAssertEqual(far.min() ?? 0, hole.depth, accuracy: 0.6)
        XCTAssertEqual(far.max() ?? 0, hole.depth, accuracy: 0.6,
                       "the bottom edge steps by \((far.max() ?? 0) - hole.depth)pt where it "
                       + "leaves the hole — at one depth there is nothing to step")
    }

    /// **The size setting does not come into it.**
    ///
    /// However big the notch is set to be, merged it is the size of the Mac's
    /// own notch. Anything else is a distortion rather than a size: the depth
    /// cannot follow the setting — one shape, one thickness — so a setting that
    /// moved everything *except* the depth gave rings capped by the cutout but
    /// spaced for a bar three times as deep.
    func testTheSizeSettingDoesNotChangeIt() throws {
        let screen = Notched()
        let reference = model(screen, scale: 1)
        for scale in [0.5, 0.589, 1.0, 1.5] as [CGFloat] {
            let m = model(screen, scale: scale)
            XCTAssertEqual(m.requestedScale, scale, accuracy: 0.001,
                           "the setting itself must survive — it governs every other edge")
            XCTAssertEqual(m.sizeScale, reference.sizeScale, accuracy: 0.001,
                           "scale \(scale): the notch is drawn at the setting, not at the "
                           + "size of the Mac's notch")
            XCTAssertEqual(m.shapeLength * m.sizeScale,
                           reference.shapeLength * reference.sizeScale, accuracy: 0.001,
                           "scale \(scale): it is a different length")
            XCTAssertEqual(m.ringCenter(index: 0) * m.sizeScale,
                           reference.ringCenter(index: 0) * reference.sizeScale, accuracy: 0.001,
                           "scale \(scale): its rings are in a different place")
        }

        // And on a display with no hole the setting is all there is.
        XCTAssertEqual(model(Plain(), scale: 1.5).sizeScale, 1.5, accuracy: 0.001)
    }

    /// **Every proportion in it is the design's**, which is what taking one
    /// scale buys over pinning the depth and letting the rest follow a slider.
    /// The contents fit the depth, and the clear space around the ring is the
    /// frame's own share of it.
    func testItKeepsTheDesignsProportionsAtTheHardwaresSize() throws {
        let screen = Notched()
        let hole = try hole(screen)
        for reading in [true, false] {
            let m = model(screen)
            m.showsNotchReadings = reading
            let scale = try XCTUnwrap(m.mergedScale)
            let cell = (m.showsCellReading ? NotchLayout.cellExtent
                                           : NotchLayout.ringDiameter) * scale
            let clear = NotchLayout.ringMargin(for: .top) * scale

            XCTAssertEqual(cell + 2 * clear, hole.depth + NotchRootView.bezelBleed,
                           accuracy: 0.001,
                           "reading \(reading): the contents and their margins do not add up "
                           + "to the bar they are in")
            XCTAssertGreaterThan(NotchLayout.ringDiameter * scale, 14,
                                 "reading \(reading): the ring is too small to read as a ring")
        }
    }

    /// The move handle rides at the leading tip, which is now inside the hole.
    /// Left there it would be a handle nobody can see or reach.
    func testTheMoveHandleStaysOnTheVisibleBar() {
        let merged = model(Notched())
        XCTAssertEqual(merged.moveAlong, merged.cutoutBleed, accuracy: 0.001)
        XCTAssertEqual(model(Plain()).moveAlong, 0, accuracy: 0.001)
    }

    // MARK: - Knowing when not to

    /// **Nudged off the hole, it is a notch like any other.**
    ///
    /// ⌥-drag moves the notch along the edge. Up to `cutoutReach` the join
    /// simply reaches further; past that the notch is somewhere else on the
    /// bezel and pretending otherwise would draw a bridge to a hole that is no
    /// longer there.
    func testItLetsGoOnceItHasBeenDraggedClear() {
        let screen = Notched()
        XCTAssertNotNil(model(screen, offset: 0).cutout)
        XCTAssertNil(model(screen, offset: 400).cutout,
                     "dragged half a screen away it is still claiming to be merged")
        XCTAssertNil(model(screen, offset: -200).cutout,
                     "dragged out the far side of the hole it is still claiming to be merged")
    }

    /// **A gap is not a join.**
    ///
    /// The bridge reached across one for a while, on the reasoning that two
    /// shapes a few points apart still read as one object. They do not: what is
    /// drawn at the joined end is a square tip and a flat run at the hole's own
    /// depth, and the only reason that may be square is that it is *inside* the
    /// hole where nothing shows. Over a gap it is a hard cut edge hanging in the
    /// open on a shape that has no other straight edge anywhere.
    func testAGapIsNotAJoin() {
        let screen = Notched()
        for nudged in [CGFloat(1), 4, 12, 30] {
            let m = model(screen, offset: nudged)
            XCTAssertFalse(m.mergesWithCutout,
                           "nudged \(nudged)pt off the hole it still draws the join, and "
                           + "the square end of it is out in the open")
            XCTAssertEqual(m.wings.filter { $0.length > 0 }.count, 1,
                           "nudged \(nudged)pt off, it is one bar")
            XCTAssertEqual(m.cutoutBleed, 0,
                           "nudged \(nudged)pt off, nothing of it is buried")
        }
        // Right up against it, it is joined.
        XCTAssertTrue(model(screen, offset: 0).mergesWithCutout)
        XCTAssertTrue(model(screen, offset: -1).mergesWithCutout)

        // And the window is the same either side of that, which is the whole
        // reason the cutout is still reported once the join has gone: a window
        // frame is set in one step, so a join that moved it would drag a third
        // of a screen of slide behind it.
        let joined = model(screen, offset: 0)
        let apart = model(screen, offset: 12)
        XCTAssertEqual(apart.panelSize.width, joined.panelSize.width, accuracy: 0.001,
                       "the window resizes as the notch takes the hole")
        XCTAssertEqual(apart.slack, joined.slack, accuracy: 0.001)
    }

    /// **A nudge toward the hole is not a reason to let go of it.**
    ///
    /// The bug: the join was gated on how far the notch had been ⌥-dragged from
    /// the placement it was given, and a -42pt nudge was already saved for the
    /// top edge on the machine this was written for. That is not a notch parked
    /// somewhere else on the bezel — it is a notch *deeper inside the hole*,
    /// which is the one direction that cannot part the two. It drew no join at
    /// all, on the only display that has a hole to join.
    func testANudgeIntoTheHoleStaysJoined() throws {
        let screen = Notched()
        for offset in [CGFloat(-6), -18, -42] {
            let m = model(screen, scale: 0.589, offset: offset)
            let near = try XCTUnwrap(m.cutout, "a nudge of \(offset)pt *into* the hole let go of it")
            XCTAssertGreaterThanOrEqual(near.overlap, NotchGeometry.cutoutOverlap,
                                        "offset \(offset): joined, but not buried enough "
                                        + "to hide the square end of the join")

            // And the bar still starts at the wall, as it does with no nudge:
            // everything buried in the hole is paid for in length.
            let hole = try hole(screen)
            // Whichever wall it has ended up against.
            let wall = near.atTrailingEnd ? hole.left : hole.wall
            let deepest = outline(of: m, on: screen)
                .filter { near.atTrailingEnd ? $0.x > wall + 0.5 : $0.x < wall - 0.5 }
                .map(\.depth).max() ?? 0
            XCTAssertLessThanOrEqual(deepest, hole.depth + 0.6, "offset \(offset)")
        }
    }

    // MARK: - The other side of the hole

    /// **It merges on the left of the cutout too.**
    ///
    /// It did not, and there was no reason for it beyond the order the two
    /// sides were built in: the bridge was written at the leading end because
    /// that is the end the default placement puts against the hole. Dragged past
    /// the cutout the notch sits on its left, where the end that meets the hole
    /// is its trailing one — the same join, at the other end of the same shape.
    func testItMergesOnTheLeftOfTheCutoutToo() throws {
        let screen = Notched()
        let cutout = try XCTUnwrap(screen.hardwareNotch)
        _ = cutout
        let m = model(screen, offset: try flushOnTheLeft(screen))
        let near = try XCTUnwrap(m.cutout, "dragged to the left of the hole it let go")
        XCTAssertTrue(near.atTrailingEnd, "it is still joining at the wrong end")
        XCTAssertEqual(near.overlap, NotchGeometry.cutoutOverlap, accuracy: 1.5,
                       "it should land flush against the hole's left wall")

        // And the whole run between the two sides is a join: every nudge from
        // flush on the right through to flush on the left.
        let flush = try flushOnTheLeft(screen)
        for step in stride(from: CGFloat(0), through: flush, by: flush / 12) {
            XCTAssertNotNil(model(screen, offset: step).cutout,
                            "a nudge of \(step)pt fell off the hole part way along")
        }
    }

    /// And the join is drawn at that end: nothing of the notch hangs out below
    /// the hole on that side either, and it meets the left wall at the hole's
    /// own depth.
    func testTheLeftHandJoinIsDrawnAtTheFarEnd() throws {
        let screen = Notched()
        let cutout = try XCTUnwrap(screen.hardwareNotch)
        let hole = try hole(screen)
        for open in [true, false] {
            let m = model(screen, open: open, offset: try flushOnTheLeft(screen))
            let drawn = outline(of: m, on: screen)

            let inside = drawn.filter { $0.x > hole.left + 0.5 }
            XCTAssertFalse(inside.isEmpty, "\(open): nothing overlaps the hole, so there "
                           + "is no join — only two shapes side by side")
            XCTAssertLessThanOrEqual(inside.map(\.depth).max() ?? 0, hole.depth + 0.6,
                                     "\(open): it hangs \(inside.map(\.depth).max() ?? 0)pt "
                                     + "below a hole \(hole.depth)pt deep")

            let atWall = drawn.filter { abs($0.x - hole.left) < 1.5 }.map(\.depth)
            XCTAssertEqual(atWall.max() ?? 0, hole.depth, accuracy: 1.0,
                           "\(open): it meets the hole's left wall at \(atWall.max() ?? 0)pt "
                           + "against the hole's \(hole.depth) — a step is a seam")
        }
    }

    /// **Let go near the hole and it lands on the nearer wall.**
    ///
    /// Answered both ways: where to glide to, and how to keep it once it has
    /// joined. They must be the same wall, or the second half of the landing
    /// sends it somewhere else.
    func testItLandsOnTheNearerWall() throws {
        let screen = Notched()
        let cutout = try XCTUnwrap(screen.hardwareNotch)
        let bar: CGFloat = 150
        let onTheLeft = 2 * NotchGeometry.cutoutOverlap - cutout.width - bar
        for (letGo, expected) in [(CGFloat(0), CGFloat(0)), (20, 0), (-30, 0),
                                  (onTheLeft, onTheLeft), (onTheLeft - 20, onTheLeft),
                                  (onTheLeft + 30, onTheLeft)] {
            let landing = try XCTUnwrap(
                NotchGeometry.cutoutLanding(alongOffset: letGo, width: cutout.width, bar: bar),
                "let go at \(letGo)pt, it was not near the hole at all")
            XCTAssertEqual(landing.free, expected, accuracy: 0.001,
                           "let go at \(letGo)pt, it glided somewhere else")
            let stand = NotchGeometry.cutoutStanding(alongOffset: landing.standing)
            XCTAssertEqual(stand.overlap, NotchGeometry.cutoutOverlap, accuracy: 0.001)
            XCTAssertEqual(stand.atTrailingEnd, expected != 0,
                           "let go at \(letGo)pt, it glided to one wall and joined the other")
        }
        XCTAssertNil(NotchGeometry.cutoutLanding(alongOffset: 400, width: cutout.width, bar: bar),
                     "out of reach, something still pulls at it")
    }

    /// **The other copy does not wait for nothing.**
    ///
    /// The bug: every landing paused before joining, so the second copy of the
    /// bar turned up late — but most drags are let go with the end already
    /// inside the hole, where there is nothing to wait for. Only a notch let go
    /// outside the hole still has to reach it first.
    func testItOnlyWaitsWhenItHasToReachTheHole() throws {
        let cutout = try XCTUnwrap(Notched().hardwareNotch)
        let bar: CGFloat = 150
        let V = NotchGeometry.cutoutOverlap
        let left = 2 * V - cutout.width - bar
        for (letGo, atOnce) in [(CGFloat(0), true), (V - 1, true), (-20, true),
                                (V + 1, false), (40, false),
                                (left, true), (left - V + 1, true),
                                (left - V - 1, false), (left - 40, false)] {
            let landing = try XCTUnwrap(
                NotchGeometry.cutoutLanding(alongOffset: letGo, width: cutout.width, bar: bar))
            XCTAssertEqual(landing.joinsAtOnce, atOnce,
                           "let go at \(letGo)pt it " + (atOnce ? "waited for nothing"
                                                                 : "joined before its end was inside the hole"))
        }
    }

    // MARK: - A whole drag, tick by tick

    /// Where the panel lands on screen for the model as it stands.
    private func panel(_ m: NotchViewModel, _ screen: ScreenDescribing) -> CGRect {
        NotchGeometry.panelFrame(
            for: screen, panelSize: m.panelSize, edge: .top,
            alongOffset: m.alongOffset, slack: m.slack,
            trailingExtent: m.trailingExtent, leadingExtent: m.leadingExtent,
            heldBar: m.holdsOffTheCutout ? m.plainBarLength : nil)
    }

    /// What of the window the notch is laid out from: its left edge, its width
    /// and its top. The height below is room for a card and changes with the
    /// card — by a whole session row when the drawn size changes — without
    /// moving anything on the top edge, which is laid out from the top.
    private func frameOfReference(_ m: NotchViewModel,
                                  _ screen: ScreenDescribing) -> [CGFloat] {
        let f = panel(m, screen)
        return [f.minX, f.width, f.maxY]
    }

    /// The carrying copy's two ends on screen.
    private func ends(_ m: NotchViewModel, _ screen: ScreenDescribing) -> (CGFloat, CGFloat) {
        let lead = panel(m, screen).minX + m.cellWing.lead
        return (lead, lead + m.notchLength * m.sizeScale)
    }

    /// **Picked up, dragged across both sides of the hole, and put down.**
    ///
    /// Every property the drag was missing, asked of one drag from end to end:
    ///
    /// - picked up, it lets go of the hole *without the window moving*, so the
    ///   letting-go can be eased;
    /// - in the hand it follows the pointer point for point — no stretch where
    ///   nothing moves, no side-hop — and is never drawn joined, so there is no
    ///   square end on the wallpaper;
    /// - put down near the hole it glides onto the nearer wall and then joins
    ///   it, and neither half moves the window or sends the bar anywhere but
    ///   where it was going.
    func testAWholeDrag() throws {
        let screen = Notched()
        let hole = try hole(screen)
        let m = model(screen)
        XCTAssertTrue(m.mergesWithCutout, "it should start joined")
        let resting = frameOfReference(m, screen)
        let startTip = ends(m, screen).0

        // Picked up.
        m.holdsOffTheCutout = true
        m.alongOffset = NotchGeometry.freeOffset(fromStanding: m.alongOffset,
                                                 width: 220, bar: m.plainBarLength)
        m.adopt(screen: screen)
        XCTAssertFalse(m.mergesWithCutout, "in the hand it is still joined")
        XCTAssertEqual(frameOfReference(m, screen), resting, "picking it up moved the window")
        XCTAssertEqual(ends(m, screen).0, startTip, accuracy: 0.5,
                       "picking it up moved its leading tip")

        // Dragged right, back, and all the way past the hole to the left.
        var path: [CGFloat] = Array(stride(from: 0, through: 120, by: 1))
        path += Array(stride(from: 120, through: -520, by: -1))
        var previous: CGFloat?
        for a in path {
            m.alongOffset = a
            m.adopt(screen: screen)
            XCTAssertFalse(m.mergesWithCutout, "at \(a) the join is drawn while in the hand")
            XCTAssertNil(m.notchShape(for: m.cellWing).cutout,
                         "at \(a) the square joined end is drawn on the wallpaper")
            XCTAssertEqual(m.wings.filter { $0.length > 0 }.count, 1,
                           "at \(a) a second copy is showing while in the hand")
            let tip = ends(m, screen).0
            XCTAssertEqual(tip, hole.wall - NotchGeometry.cutoutOverlap + a, accuracy: 0.5,
                           "at \(a) the bar is not under the pointer")
            // A point of pointer per tick, and the window is set in whole
            // points, so two ticks can differ by up to a point and two
            // half-point roundings — never more.
            if let previous {
                XCTAssertLessThanOrEqual(abs(tip - previous), 2,
                                         "at \(a) the bar jumped \(tip - previous)pt in one tick")
            }
            previous = tip
        }

        // Put down near the hole's left wall.
        let bar = m.plainBarLength
        let letGo = 2 * NotchGeometry.cutoutOverlap - 220 - bar + 15
        m.alongOffset = letGo
        m.adopt(screen: screen)
        let before = frameOfReference(m, screen)
        let landing = try XCTUnwrap(NotchGeometry.cutoutLanding(alongOffset: letGo,
                                                                width: 220, bar: bar))
        // The other copy is there before it is let go, all inside the hole, on
        // the side it will come out of.
        let waiting = try XCTUnwrap(m.wings.first { !$0.carriesCells })
        XCTAssertEqual(waiting.length, 0, "the notch has widened before it was let go")
        XCTAssertFalse(waiting.onTheLeft, "put down on the left, the other copy is on the left too")

        // First half: the glide, still in the hand — and the other copy coming
        // out of its wall at the same moment, not after.
        m.revealsTheOtherCopy = true
        m.alongOffset = landing.free
        m.adopt(screen: screen)
        let coming = try XCTUnwrap(m.wings.first { !$0.carriesCells })
        XCTAssertGreaterThan(coming.length, 0, "the other side waits for the glide to finish")
        XCTAssertEqual(coming.id, waiting.id)
        XCTAssertEqual(coming.onTheLeft, waiting.onTheLeft, "the other copy changed sides")
        XCTAssertEqual(frameOfReference(m, screen), before, "the glide moved the window")
        let glided = ends(m, screen).1
        XCTAssertEqual(glided, hole.left + NotchGeometry.cutoutOverlap, accuracy: 0.5,
                       "it glided somewhere other than flush on the left wall")
        // Second half: it takes the hole.
        m.revealsTheOtherCopy = false
        m.holdsOffTheCutout = false
        m.alongOffset = landing.standing
        m.adopt(screen: screen)
        let arrived = try XCTUnwrap(m.wings.first { !$0.carriesCells })
        XCTAssertGreaterThan(arrived.length, 0, "joining took the widening back in")
        XCTAssertEqual(arrived.id, coming.id)
        XCTAssertEqual(arrived.onTheLeft, coming.onTheLeft)
        func wallEnd(_ w: NotchViewModel.Wing) -> CGFloat {
            w.onTheLeft ? w.lead + w.length : w.lead
        }
        XCTAssertEqual(wallEnd(arrived), wallEnd(coming), accuracy: 0.5,
                       "the widening came off its wall when the join caught up with it")
        XCTAssertTrue(m.mergesWithCutout, "put down against the hole, it did not join it")
        XCTAssertEqual(frameOfReference(m, screen), before, "joining moved the window")
        XCTAssertTrue(m.cellWing.onTheLeft, "put down on the left, the readings went right")
        XCTAssertEqual(ends(m, screen).1, glided, accuracy: 0.5,
                       "joining sent its joined end somewhere else")
    }

    /// **Joining is a number easing, not a shape being swapped.**
    ///
    /// The bar the readings are on used to become a different kind of shape the
    /// instant it joined — its flared end replaced by the joined end in one
    /// frame, with part of that flare outside the hole where the jump showed.
    /// It is the same shape either side of the join now, and the only thing
    /// that changes is `leadingJoin`, which SwiftUI eases through
    /// `animatableData` on the spring the rest of the notch is on.
    func testJoiningEasesTheEndRatherThanSwappingIt() throws {
        let screen = Notched()
        let joined = model(screen)
        let apart = model(screen, offset: 30)
        for m in [joined, apart] {
            XCTAssertNil(m.notchShape(for: m.cellWing).cutout,
                         "the carrying bar is drawn as a different kind of shape")
        }
        XCTAssertEqual(joined.notchShape(for: joined.cellWing).leadingJoin, 1)
        XCTAssertEqual(apart.notchShape(for: apart.cellWing).leadingJoin, 0)

        // And it is carried by `animatableData`, which is what lets it ease.
        var shape = SideNotchShape(edge: .top)
        var data = shape.animatableData
        data.second.second.second = 0.4
        shape.animatableData = data
        XCTAssertEqual(shape.leadingJoin, 0.4, accuracy: 0.0001,
                       "leadingJoin is not animatable, so the join would snap")
        data = shape.animatableData
        data.second.first.second = 0.3
        shape.animatableData = data
        XCTAssertEqual(shape.trailingFlare, 0.3, accuracy: 0.0001,
                       "the far end's flare is not animatable, so it would snap")
    }

    /// **Joined, the two sides are the same shape.**
    ///
    /// Both end with the notch's own curve — the one the side with the readings
    /// has — the same corner, the same length, mirror images of each other about
    /// the hole.
    func testTheTwoSidesBalance() throws {
        let screen = Notched()
        for offset in [CGFloat(0), -2 * NotchGeometry.cutoutTravel] {
            let m = model(screen, offset: offset)
            XCTAssertTrue(m.mergesWithCutout)
            let carrying = m.cellWing
            let other = try XCTUnwrap(m.wings.first { !$0.carriesCells })
            let a = m.notchShape(for: carrying), b = m.notchShape(for: other)
            XCTAssertEqual(a.cornerRadius, b.cornerRadius, accuracy: 0.001,
                           "the two sides turn different corners")
            XCTAssertEqual(a.trailingFlare, 1, "the side with the readings lost its curve")
            XCTAssertEqual(b.trailingFlare, 1, "the other side lost its curve")
            XCTAssertEqual(a.leadingJoin, b.leadingJoin)
            XCTAssertEqual(carrying.length, other.length, accuracy: 0.001)
            XCTAssertEqual(carrying.depth, other.depth, accuracy: 0.001)
            XCTAssertNotEqual(carrying.onTheLeft, other.onTheLeft, "both on one side")

            // And on screen: each reaches the same distance out from its wall.
            let hole = try hole(screen)
            let drawn = outline(of: m, on: screen)
            let leftReach = hole.left - (drawn.map(\.x).min() ?? 0)
            let rightReach = (drawn.map(\.x).max() ?? 0) - hole.wall
            XCTAssertEqual(leftReach, rightReach, accuracy: 1.0,
                           "offset \(offset): one side reaches further than the other")
        }
        // Apart from the hole it is the notch it is on every other edge.
        let apart = model(screen, offset: 6)
        XCTAssertEqual(apart.notchShape(for: apart.cellWing).trailingFlare, 1)
    }

    // MARK: - The magnet

    /// **Near the hole it pulls, holds, and lets go with a snap** — and never
    /// jumps or runs backwards to do it.
    func testTheHolesPullIsAMagnet() {
        let W: CGFloat = 220, bar: CGFloat = 150
        let C = NotchGeometry.cutoutCapture, g = NotchGeometry.cutoutGrip
        let left = 2 * NotchGeometry.cutoutOverlap - W - bar
        for target in [CGFloat(0), left] {
            func pulled(_ d: CGFloat) -> CGFloat {
                NotchGeometry.magnetised(target + d, width: W, bar: bar) - target
            }
            // At the spot it sits heavy: a point of pointer is a fraction of one.
            XCTAssertEqual(pulled(1), g, accuracy: 0.01, "it does not hold on")
            XCTAssertEqual(pulled(0), 0, accuracy: 0.0001)
            // Out past the pull it follows the pointer exactly.
            XCTAssertEqual(pulled(C + 5), C + 5, accuracy: 0.0001)
            XCTAssertEqual(pulled(-C - 5), -C - 5, accuracy: 0.0001)
            // And at the edge of the pull it meets the pointer — nothing to
            // jump across, coming in or breaking free.
            XCTAssertEqual(pulled(C - 0.001), C, accuracy: 0.01)
            XCTAssertEqual(pulled(-C + 0.001), -C, accuracy: 0.01)
            // Steeper than the pointer near that edge: drawn in ahead of it, and
            // snapping to catch up as it breaks free.
            XCTAssertGreaterThan(pulled(C - 1) - pulled(C - 2), 1.5,
                                 "it does not snap — it drifts")
            // It never runs backwards.
            var last = pulled(-C - 2)
            for d in stride(from: -C - 1.5, through: C + 2, by: 0.5) {
                let now = pulled(d)
                XCTAssertGreaterThanOrEqual(now, last, "at \(d) it moved against the pointer")
                last = now
            }
        }
    }

    /// **The other side is the notch widening, with the same curve.**
    ///
    /// Always exactly the hole's depth, and ending with the notch's own curve —
    /// the flare and the corner the side with the readings has — never the
    /// hardware's square end. It widens by being drawn longer: nothing at all
    /// until the notch is joined, the carrying side's own length once it is.
    func testTheOtherSideIsTheNotchWidening() throws {
        let screen = Notched()
        let hole = try hole(screen)
        for scale in [0.5, 1.0, 1.5] as [CGFloat] {
            let m = model(screen, scale: scale)
            let widening = try XCTUnwrap(m.wings.first { !$0.carriesCells })
            XCTAssertEqual(widening.depth * m.sizeScale - NotchRootView.bezelBleed,
                           hole.depth, accuracy: 0.001,
                           "scale \(scale): the notch widened to a different depth")
            let shape = m.notchShape(for: widening)
            XCTAssertEqual(shape.trailingFlare, 1, "it lost the curve")
            XCTAssertEqual(shape.cornerRadius, m.drawnCornerRadius, accuracy: 0.001,
                           "scale \(scale): its corner is not the notch's own")
            XCTAssertEqual(widening.length, m.notchLength * m.sizeScale, accuracy: 0.001,
                           "scale \(scale): it widened by a different amount on each side")
        }
        // Near the hole but not joined to it, it has not widened at all.
        let apart = model(screen, offset: 6)
        XCTAssertFalse(apart.mergesWithCutout)
        XCTAssertEqual(try XCTUnwrap(apart.wings.first { !$0.carriesCells }).length, 0,
                       "the notch widened before anything joined it")
    }

    /// No hole, no join — on a plain display and on the other three edges.
    func testOnlyTheTopEdgeOfANotchedDisplayMerges() {
        XCTAssertNil(model(Plain()).cutout)
        for edge in [NotchEdge.right, .left, .bottom] {
            let m = NotchViewModel()
            m.edge = edge
            m.adopt(screen: Notched())
            XCTAssertNil(m.cutout, "\(edge) is merging with a hole it never touches")
            XCTAssertNil(m.notchShape.cutout, "\(edge)")
        }
    }
}
