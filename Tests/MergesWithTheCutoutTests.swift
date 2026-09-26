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
        let path = m.notchShape.path(in: CGRect(origin: .zero, size: m.notchSize))
        let lead = frame.minX + m.notchAlongLead
        let place = { (p: CGPoint) in
            Sample(x: lead + p.x * m.sizeScale,
                   depth: p.y * m.sizeScale - NotchRootView.bezelBleed)
        }

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
                cursor = to
                samples.append(place(to))
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
    private func hole(_ screen: ScreenDescribing) throws -> (wall: CGFloat, depth: CGFloat) {
        let cutout = try XCTUnwrap(screen.hardwareNotch)
        return (screen.frameValue.midX + cutout.width / 2, cutout.height)
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
        XCTAssertGreaterThan(bridge.count, 8, "the bridge is too coarse to measure")

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
    func testItFoldsTowardTheHoleRatherThanItsOwnCentre() {
        let m = model(Notched())
        let open = m.notchAlongLead
        m.isExpanded = false
        XCTAssertEqual(m.notchAlongLead, open, accuracy: 0.001,
                       "the folded notch let go of the hole")
        XCTAssertEqual(m.notchAlongLead, m.slack, accuracy: 0.001)

        // And a notch with no hole to hold on to still contracts in place.
        let plain = model(Plain())
        let openCentre = plain.notchAlongLead + plain.notchLength * plain.sizeScale / 2
        plain.isExpanded = false
        XCTAssertEqual(plain.notchAlongLead + plain.notchLength * plain.sizeScale / 2,
                       openCentre, accuracy: 0.001,
                       "a notch with no hole should still fold to its own centre line")
    }

    /// The buried overlap is length nobody sees, so the bar is drawn longer by
    /// exactly that much — otherwise the merged notch is a shorter notch, and
    /// its rings sit closer to its visible start than they do on any other edge.
    func testTheBuriedOverlapIsPaidForInLength() {
        let merged = model(Notched())
        let plain = model(Plain())
        XCTAssertEqual(merged.cutoutBleed * merged.sizeScale,
                       NotchGeometry.cutoutOverlap, accuracy: 0.001)
        XCTAssertEqual(merged.shapeLength - merged.cutoutBleed, plain.shapeLength,
                       accuracy: 0.001, "the visible bar is not the same bar")
        XCTAssertEqual(merged.cellsLeadIn - merged.cutoutBleed, plain.cellsLeadIn,
                       accuracy: 0.001, "the first ring moved relative to the visible start")
        for index in 0..<3 {
            XCTAssertEqual(merged.ringCenter(index: index) - merged.cutoutBleed,
                           plain.ringCenter(index: index), accuracy: 0.001, "ring \(index)")
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
        XCTAssertNotNil(model(screen, offset: NotchGeometry.cutoutOverlap).cutout,
                        "flush with the wall is still joined")
        XCTAssertNil(model(screen, offset: 400).cutout,
                     "dragged half a screen away it is still claiming to be merged")
        XCTAssertNil(model(screen, offset: -400).cutout,
                     "dragged out the far side of the hole it is still claiming to be merged")

        // Reaching back for it, the bridge starts left of the notch's own tip.
        let reaching = model(screen, offset: NotchGeometry.cutoutOverlap + 10)
        XCTAssertEqual(reaching.cutout?.overlap, -10)
        XCTAssertEqual(reaching.cutoutBleed, 0,
                       "there is nothing buried when the two are apart, so there is "
                       + "nothing to pay for in length")
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
        for offset in [CGFloat(-42), -80, -120] {
            let m = model(screen, scale: 0.589, offset: offset)
            let near = try XCTUnwrap(m.cutout, "a nudge of \(offset)pt *into* the hole let go of it")
            XCTAssertEqual(near.overlap, NotchGeometry.cutoutOverlap - offset, accuracy: 0.001)

            // And the bar still starts at the wall, as it does with no nudge:
            // everything buried in the hole is paid for in length.
            let hole = try hole(screen)
            let deepest = outline(of: m, on: screen)
                .filter { $0.x < hole.wall - 0.5 }.map(\.depth).max() ?? 0
            XCTAssertLessThanOrEqual(deepest, hole.depth + 0.6, "offset \(offset)")
        }
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
