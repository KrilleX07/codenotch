import SwiftUI
import XCTest
@testable import Codenotch

/// A MacBook's own notch, as this machine reports it.
private let realNotch = HardwareNotch(width: 220, height: 38)

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
    var hardwareNotch: HardwareNotch?
}

private let notched = FakeScreen(
    frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrameValue: CGRect(x: 0, y: 59, width: 1800, height: 1071),
    hardwareNotch: realNotch
)

private let plain = FakeScreen(
    frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1144),
    hardwareNotch: nil
)

/// On a Mac that has a notch of its own, a top-edge Codenotch runs up to meet
/// it so the two read as one shape rather than as a bar parked underneath.
final class HardwareNotchGeometryTests: XCTestCase {
    private let size = CGSize(width: 700, height: 200)

    func testATopNotchRunsUpToTheRealTopToMeetTheHardware() {
        let frame = NotchGeometry.panelFrame(for: notched, panelSize: size, edge: .top)
        XCTAssertEqual(frame.maxY, notched.frameValue.maxY, accuracy: 0.001,
                       "it stopped below the menu bar instead of meeting the notch")
    }

    func testWithoutOneItStillReachesThePhysicalTopEdge() {
        let frame = NotchGeometry.panelFrame(for: plain, panelSize: size, edge: .top)
        XCTAssertEqual(frame.maxY, plain.frameValue.maxY, accuracy: 0.001)
    }

    /// Hardware merging only affects the top edge.
    func testTheOtherEdgesAreUnaffectedByIt() {
        XCTAssertEqual(
            NotchGeometry.panelFrame(for: notched, panelSize: size, edge: .bottom).minY,
            notched.frameValue.minY, accuracy: 0.001
        )
        XCTAssertEqual(
            NotchGeometry.panelFrame(for: notched, panelSize: CGSize(width: 300, height: 700), edge: .right).maxX,
            notched.frameValue.maxX, accuracy: 0.001
        )
    }

    func testItReadsTheNotchFromTheAreasEitherSideOfIt() {
        XCTAssertEqual(realNotch.width, 220, accuracy: 0.001)
        XCTAssertEqual(realNotch.height, 38, accuracy: 0.001)
    }
}

/// Merging costs two things, and forgetting either one is what makes it look
/// broken rather than joined.
@MainActor
final class MergedTopNotchTests: XCTestCase {
    private func model(cells: Int, screen: ScreenDescribing = notched,
                       edge: NotchEdge = .top) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = edge
        model.isExpanded = true
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: screen)
        return model
    }

    // MARK: - Beside the hardware, not below it

    /// The rings used to be stacked *under* the hole, which cost the app the
    /// hardware's own depth before it drew anything. They are beside it now, so
    /// nothing is inset and the hole is left as a gap in the middle of the bar.
    func testTheRingsAreBesideTheHoleRatherThanBelowIt() {
        let model = model(cells: 4)
        XCTAssertEqual(model.contentInset, 0, accuracy: 0.001,
                       "the rings are still being pushed below the hardware")
        XCTAssertGreaterThanOrEqual(
            model.splitGap * model.sizeScale, realNotch.width,
            "the gap left for the hole is narrower than the hole"
        )
    }

    /// And the shape is the hardware's own depth rather than that depth plus a
    /// stack — the whole point of the placement is that it reads as the notch.
    func testTheShapeIsExactlyAsDeepAsTheHardware() {
        let merged = model(cells: 4).notchDepth
        let plainTop = model(cells: 4, screen: plain).notchDepth
        XCTAssertEqual(merged - NotchRootView.bezelBleed, realNotch.height, accuracy: 0.001,
                       "the bar is not the hardware's depth")
        XCTAssertLessThan(merged, plainTop,
                          "it is no shallower than the stack it replaced")
    }

    /// **Folded away it is the hardware notch exactly**: same width, same depth.
    ///
    /// It folded to the small pill the other edges use for a while. That hides
    /// inside the hole just as well, but the fold is an animation, and what
    /// that one animated was a 68pt tab in the middle of a 220pt hole growing
    /// outward — the ears appeared to come out of a point rather than out of
    /// the notch. Starting as the cutout makes opening it widen the hardware:
    /// the shape is the hole's width on the first frame, and every frame after
    /// only adds ear.
    func testFoldedAwayItIsExactlyTheHardwareNotch() {
        let m = model(cells: 4)
        m.isExpanded = false
        XCTAssertEqual(m.notchLength, realNotch.width, accuracy: 0.001,
                       "the resting shape is not the cutout's width")
        XCTAssertEqual(m.notchDepth - NotchRootView.bezelBleed, realNotch.height,
                       accuracy: 0.001, "the resting shape is not the cutout's depth")
    }

    /// **Nothing of it hangs below the hardware.** Anything drawn under the
    /// cutout's lip makes the notch read as deeper than the one the display
    /// has, which is the whole of what is wrong with doing it.
    func testNothingOfItHangsBelowTheHardware() {
        let m = model(cells: 4)
        m.isExpanded = false
        let below = m.notchDepth - NotchRootView.bezelBleed - realNotch.height
        XCTAssertLessThanOrEqual(below, 0.001,
                                 "\(below)pt of the folded notch hangs below the cutout")
    }

    /// Opening it grows the ears sideways and leaves the depth alone: the
    /// cutout's, folded or open.
    func testOpeningGrowsTheEarsWithoutDeepeningTheNotch() {
        let m = model(cells: 4)
        m.isExpanded = false
        let (restLength, restDepth) = (m.notchLength, m.notchDepth)
        m.isExpanded = true
        XCTAssertGreaterThan(m.notchLength, restLength)
        XCTAssertEqual(m.notchDepth, restDepth, accuracy: 0.001,
                       "opening it made the notch deeper than the hardware")
    }

    /// A screen without one keeps the pill it always had.
    func testWithoutAHardwareNotchItStillFoldsToItsPill() {
        let m = model(cells: 4, screen: plain)
        m.isExpanded = false
        XCTAssertEqual(m.notchLength, NotchLayout.pillHeight, accuracy: 0.001)
        XCTAssertEqual(m.notchDepth, NotchLayout.pillWidth, accuracy: 0.001)
    }

    /// Nothing below the hardware wakes it.
    ///
    /// The pill's band exists because a 10pt sliver is hard to hit. The notch
    /// is 220 by 38 and needs no help — and the band it inherited ran 34pt
    /// below the menu bar, across the title bar of a window tiled to the
    /// centre of the screen. Aiming at that window's close button opened the
    /// notch on top of the button.
    func testWhatWakesItIsExactlyTheHardwareNotch() {
        let m = model(cells: 4)
        m.isExpanded = false
        XCTAssertEqual(m.wakeLength, realNotch.width, accuracy: 0.001,
                       "the wake region is wider than the hardware")
        // The hole and nothing more: no band below it.
        XCTAssertEqual(m.wakeDepth, realNotch.height, accuracy: 0.001,
                       "the wake region reaches below the hole, into the window under it")
    }

    /// The pill keeps its band: it is the small target the band was made for.
    func testThePillIsStillWokenByABandAroundIt() {
        let m = model(cells: 4, screen: plain)
        m.isExpanded = false
        XCTAssertGreaterThan(m.wakeDepth, m.restingDepth,
                             "the pill lost the band that makes it hittable")
        XCTAssertGreaterThanOrEqual(m.wakeLength, m.restingLength)
    }

    func testAScreenWithoutOneInsetsNothing() {
        XCTAssertEqual(model(cells: 4, screen: plain).contentInset, 0, accuracy: 0.001)
        for edge in [NotchEdge.right, .left, .bottom] {
            XCTAssertEqual(model(cells: 4, edge: edge).contentInset, 0, accuracy: 0.001,
                           "\(edge) has no hardware notch to clear")
        }
    }

    // MARK: - Being at least as wide as the thing it joins

    /// The second cost: a single ring makes a bar about 194pt across, and this
    /// Mac's notch is 220. Left alone the hardware would be *wider* than the
    /// shape that is supposed to be it, sticking out either side.
    ///
    /// Measured on the drawn shape rather than on the body: with the flares
    /// gone, the shape's whole length is what meets the screen's top edge, and
    /// that is what has to clear the hardware.
    func testTheDrawnBarIsNeverNarrowerThanTheHardwareNotch() {
        for count in 1...5 {
            XCTAssertGreaterThanOrEqual(
                model(cells: count).shapeLength, realNotch.width,
                "\(count) cells: the hardware notch is wider than the shape replacing it"
            )
        }
    }

    /// The stack is two groups now, one either side of the hole, so "centred"
    /// is the wrong test — with an odd count the left group carries the extra
    /// ring and the two are deliberately different lengths. What must match is
    /// the *margin*: the bar ends the same distance past its outermost ring at
    /// each end, which is the padding being equal left and right.
    ///
    /// From two rings up: one ring is an ear on one side and nothing on the
    /// other, so its "margin" at the empty end is the hole itself.
    func testEachEndOfTheBarKeepsTheSameMargin() {
        for count in 2...5 {
            let model = model(cells: count)
            let radius = NotchLayout.ringDiameter * model.splitCellScale / 2
            let leadingMargin = model.ringCenter(index: 0) - radius
            let trailingMargin =
                model.shapeLength - (model.ringCenter(index: count - 1) + radius)
            XCTAssertEqual(leadingMargin, trailingMargin, accuracy: 0.5,
                           "\(count) cells: \(leadingMargin)pt of bar at one end and "
                           + "\(trailingMargin)pt at the other")
        }
    }

    /// The odd case: a single ring makes one ear, and the bar stops at the far
    /// side of the hole rather than growing an empty ear to balance it.
    func testOneRingMakesOneEar() {
        let m = model(cells: 1)
        XCTAssertEqual(m.splitWidths(cellCount: 1).right, 0, accuracy: 0.001)
        XCTAssertGreaterThan(m.splitWidths(cellCount: 1).left, 0)
        XCTAssertEqual(m.shapeLength,
                       m.splitEndPads(cellCount: 1).left
                           + m.splitWidths(cellCount: 1).left + m.splitGap + 2 * m.flare,
                       accuracy: 0.001,
                       "the bar reaches past the hole with nothing to show there")
    }

    /// Once the stack is wide enough on its own, nothing is added to it.
    ///
    /// Compared against zero rather than against an unmerged notch: the two are
    /// no longer the same length even with no widening, because a flush bar
    /// reserves only the small frame corner at its ends where a flared one
    /// reserves a whole `curlRadius`.
    func testAWideStackIsLeftAlone() {
        XCTAssertEqual(model(cells: 5).endSpread, 0, accuracy: 0.001)
        XCTAssertEqual(model(cells: 4).endSpread, 0, accuracy: 0.001)
    }

    func testASideEdgeIsNeverWidenedForIt() {
        for edge in [NotchEdge.right, .left, .bottom] {
            XCTAssertEqual(model(cells: 1, edge: edge).endSpread, 0, accuracy: 0.001, "\(edge)")
        }
    }
}

/// Where the merged shape actually puts its edges.
@MainActor
final class MergedShapeTests: XCTestCase {
    private let inset = realNotch.height

    private func model(cells: Int = 4) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: notched)
        return model
    }

    /// The stretch that runs up behind the hardware is a straight extension of
    /// the bar, not part of its flare.
    ///
    /// Left as an ordinary deeper shape, the flares — which live in the first
    /// `curlRadius` from the bezel, and this Mac's notch is almost exactly that
    /// tall — would be drawn entirely inside the hole. The bar would emerge
    /// from the hardware with square corners, and the settings orb, which is
    /// concentric with the flare, would be invisible with it.
    /// **The bar is shaped like the Mac's own notch, only bigger.**
    ///
    /// **The bar is at its widest where it meets the screen's border**, and
    /// narrows from there: the ears sweep out into the border rather than
    /// ending against it.
    func testItIsAtItsWidestWhereItMeetsTheScreensBorder() {
        let m = model()
        let size = m.notchSize
        guard let atBezel = span(of: m, at: 0.3),
              let lower = span(of: m, at: 6) else { return XCTFail("nothing at the bezel") }

        XCTAssertEqual(atBezel.lowerBound, 0, accuracy: 6,
                       "the bar does not reach the top of the screen")
        XCTAssertEqual(atBezel.upperBound, size.width - 1, accuracy: 6,
                       "the bar does not reach the top of the screen")
        XCTAssertGreaterThan(atBezel.upperBound - atBezel.lowerBound,
                             lower.upperBound - lower.lowerBound,
                             "the bar is no wider at the border than below it")
    }

    /// Straight-sided between its two corner details: the small one into the
    /// screen's frame at the top, and its own rounding at the bottom. Anything
    /// varying in between would read as two shapes stacked.
    func testItKeepsTheSameWidthBetweenItsCorners() {
        let m = model()
        guard let reference = span(of: m, at: NotchLayout.bezelFillet + 2) else {
            return XCTFail("nothing below the frame corner")
        }
        for across in stride(from: NotchLayout.bezelFillet + 2,
                             to: m.notchDepth - NotchLayout.cornerRadius, by: 4) {
            guard let band = span(of: m, at: across) else {
                return XCTFail("the bar has a gap at depth \(across)")
            }
            XCTAssertEqual(band.lowerBound, reference.lowerBound, accuracy: 2,
                           "the bar changes width at depth \(across)")
            XCTAssertEqual(band.upperBound, reference.upperBound, accuracy: 2,
                           "the bar changes width at depth \(across)")
        }
    }

    /// The sweep into the frame takes a real bite out of the bar's width —
    /// that is what it is for — but the bar is still mostly bar.
    func testTheFrameCornerBarelyNarrowsTheBar() {
        let m = model()
        guard let atFrame = span(of: m, at: 0.5),
              let below = span(of: m, at: NotchLayout.bezelFillet + 2) else {
            return XCTFail("no shape to measure")
        }
        let lost = (below.lowerBound - atFrame.lowerBound)
            + (atFrame.upperBound - below.upperBound)
        XCTAssertLessThan(lost / (atFrame.upperBound - atFrame.lowerBound), 0.25,
                          "the sweep into the frame has taken over the bar")
    }

    /// And it is rounded off at the bottom, the way the hardware notch is.
    func testItsBottomCornersAreRounded() throws {
        let m = model()
        // Sampled at the foot itself. The corner is continuous, so it is
        // nearly flat where it meets the straight side and does most of its
        // turning in the last point or two — sample above that and it reads as
        // square when it is not.
        guard let atBezel = span(of: m, at: 1),
              let atFoot = span(of: m, at: m.notchDepth - 0.4) else {
            return XCTFail("no shape to measure")
        }
        // Measured against the model's own number: the frame-wide
        // `cornerRadius` is not the one drawn here.
        let pulledIn = (atFoot.lowerBound - atBezel.lowerBound)
        XCTAssertGreaterThan(pulledIn, m.drawnCornerRadius / 2,
                             "the bar has square corners at the bottom")
        XCTAssertLessThanOrEqual(pulledIn,
                                 try XCTUnwrap(m.splitFillet) + m.drawnCornerRadius + 1,
                                 "the end is losing more than the join and the corner")
        XCTAssertEqual(atFoot.lowerBound - atBezel.lowerBound,
                       atBezel.upperBound - atFoot.upperBound, accuracy: 2,
                       "the bottom corners do not match each other")
    }

    /// Sampled rather than probed: a single point can land exactly on a
    /// construction line, where `contains` is a coin toss.
    private func span(of m: NotchViewModel, at across: CGFloat) -> ClosedRange<CGFloat>? {
        let size = m.notchSize
        let place = NotchPlacement(edge: .top, panelSize: size)
        // Built the way the view builds it. A shape left on its defaults is a
        // different shape from the one on screen, and measuring that one is how
        // four of this redesign's bugs got past a green suite.
        let shape = m.notchShape
        let path = shape.path(in: CGRect(origin: .zero, size: size))
        let hits = stride(from: CGFloat(0), to: size.width, by: 1)
            .filter { path.contains(place.point(along: $0, across: across)) }
        guard let first = hits.first, let last = hits.last else { return nil }
        return first...last
    }

    /// Every other edge keeps the flares the design frame drew.
    func testTheOtherEdgesKeepTheirFlares() {
        let flared = SideNotchShape(edge: .top, joining: nil)
            .path(in: CGRect(x: 0, y: 0, width: 400, height: 140))
        let place = NotchPlacement(edge: .top, panelSize: CGSize(width: 400, height: 140))
        XCTAssertFalse(
            flared.contains(place.point(along: 2, across: NotchLayout.curlRadius + 4)),
            "the flare is missing from an ordinary notch"
        )
    }

    /// No part of the orb may be inside the hole, where it is not dimmed but
    /// simply off the display.
    ///
    /// It used to have to clear the hardware's *depth*, because the bar sat
    /// behind the hole and the orb hung off its end directly below. Beside the
    /// hole it clears it the other way — the orb is out at the ear's tip, a
    /// long way along the bezel from the cutout — so the clearance to measure
    /// is horizontal.
    func testTheWholeOrbSitsClearOfTheHole() {
        let m = model()
        let arcCentre = m.orbAlong + m.orbArcOffset.width
        let nearest = min(arcCentre - m.orbArcRadius - NotchLayout.orbStroke * m.orbScale / 2,
                          m.orbAlong - NotchLayout.orbDiameter * m.orbScale / 2)
        let holeEnd = m.shapeLength / 2 + realNotch.width / 2 - m.splitShift
        XCTAssertGreaterThan(nearest, holeEnd,
                             "part of the orb is drawn over the hole in the display")
    }

    /// And it is small enough to belong to the bar it hangs from.
    ///
    /// Every number the orb is drawn from was chosen against a stack some 30pt
    /// deeper than this one. At full size the disc is very nearly as wide as
    /// the bar, which is what made it read as an arc floating in the wallpaper.
    func testTheOrbIsScaledToTheBarItHangsFrom() {
        let m = model()
        XCTAssertLessThan(m.orbScale, 1, "the orb is still drawn at stack size")
        XCTAssertLessThan(NotchLayout.orbDiameter * m.orbScale, m.splitDrawnDepth,
                          "the disc is wider than the bar is deep")
        XCTAssertGreaterThan(m.orbScale, 0.4,
                             "shrunk past the point of being a target")
    }

    /// And the card hangs off the *bar's* foot — the cutout's depth, not the
    /// stacked layout's, which is some 60pt lower and left a stretch of
    /// wallpaper between the card's tail and the notch it points at.
    func testTheTooltipHangsOffTheBarsFoot() {
        let m = model()
        XCTAssertEqual(m.tooltipInset, m.splitDrawnDepth + NotchLayout.tailGap,
                       accuracy: 0.001)
        XCTAssertLessThan(m.tooltipInset,
                          m.contentInset + NotchLayout.bodyDepth(for: .top),
                          "the card is still being measured from the stacked depth")
    }
}

/// With the flares gone there is no concave corner for the settings orb to
/// tuck into, and left where it was it becomes a dot on the bar's edge.
///
/// Same idea, turned inside out: it hugs the bar's own rounded corner from
/// *outside* instead of a flare from inside. Hugging a corner the other way
/// round is the same relationship through half a circle, which is all the
/// trim has to do.
@MainActor
final class OrbOnAFlushBarTests: XCTestCase {
    private func model(flush: Bool) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        model.snapshots = (0..<4).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: flush ? notched : plain)
        return model
    }

    /// **The orb hangs off the bar, not inside it.**
    ///
    /// It normally nestles into the pocket the far flare cuts out of the notch —
    /// that is why it is concentric with the flare, one gap inside it. A flush
    /// bar has no pocket: its far corner is convex, so an orb centred on that
    /// corner sits *within* the black, which is where the gear was appearing.
    func testTheWholeOrbIsOutsideTheBar() {
        let m = model(flush: true)
        // Measured against the drawn path, not against the bar's end: the orb
        // hangs off the *corner*, and how far in from the end that corner sits
        // depends on the curve into the screen's edge. A big one pulls it well
        // inside, and the orb follows it there quite correctly.
        let size = m.notchSize
        let place = NotchPlacement(edge: .top, panelSize: size)
        let path = m.notchShape.path(in: CGRect(origin: .zero, size: size))
        let radius = NotchLayout.orbDiameter * m.orbScale / 2
        for step in 0..<72 {
            let angle = Double(step) / 72 * 2 * .pi
            let point = place.point(along: m.orbAlong + radius * CGFloat(cos(angle)),
                                    across: m.orbInset + radius * CGFloat(sin(angle)))
            XCTAssertFalse(path.contains(point),
                           "the settings disc overlaps the bar at \(Int(angle * 180 / .pi))°")
        }
    }

    /// Clear of the corner it hangs from by the same gap the flare version
    /// uses, so the disc never overlaps the bar it belongs to.
    ///
    /// Gap and disc are the orb's own and shrink with it; the corner is the
    /// hardware's and does not. That distinction is the whole of `orbScale`.
    func testTheDiscClearsTheCornerByTheUsualGap() {
        let m = model(flush: true)
        let corner = CGPoint(x: m.cornerCentreAlong,
                             y: m.drawnFoot - m.drawnCornerRadius)
        let reach = hypot(m.orbAlong - corner.x, m.orbInset - corner.y)
        XCTAssertEqual(
            reach - m.drawnCornerRadius - NotchLayout.orbDiameter * m.orbScale / 2,
            NotchLayout.orbGap * m.orbScale, accuracy: 0.5,
            "the settings disc is not sitting clear of the bar's corner"
        )
    }

    /// It hangs diagonally, so it reads as belonging to the corner rather than
    /// to one edge or the other.
    func testItHangsOffTheCornerDiagonally() {
        let m = model(flush: true)
        let past = m.orbAlong - m.cornerCentreAlong
        let below = m.orbInset - (m.drawnFoot - m.drawnCornerRadius)
        XCTAssertEqual(past, below, accuracy: 0.001, "the orb is off to one side")
    }

    /// And traces it one gap outside, which is the same clearance the flared
    /// version keeps from its flare.
    func testTheArcTracesTheCornerByTheUsualGap() {
        let m = model(flush: true)
        XCTAssertEqual(m.orbArcRadius - m.drawnCornerRadius,
                       NotchLayout.orbGap * m.orbScale, accuracy: 0.001)
    }

    /// Which puts them far enough apart that one hot zone cannot cover both —
    /// the arc is what you see, the button is what you are reaching for, and
    /// the handle has to answer to either.
    func testTheArcAndTheButtonNeedSeparateHitZones() {
        let m = model(flush: true)
        let apart = hypot(m.orbArcOffset.width, m.orbArcOffset.height)
        XCTAssertGreaterThan(apart, NotchLayout.orbHotZone / 2,
                             "one zone would do; the union is unnecessary")
    }

    /// Inside a flare's pocket the two are the same object, as they always were.
    func testTheyAreConcentricWhenThereIsAFlare() {
        let m = model(flush: false)
        XCTAssertEqual(m.orbArcOffset.width, 0, accuracy: 0.001)
        XCTAssertEqual(m.orbArcOffset.height, 0, accuracy: 0.001)
    }

    /// The arc faces away from the bar on both axes — out past its end, and
    /// down past its foot. That is what makes it read as hugging the corner.
    func testTheArcFacesAwayFromTheBar() {
        let range = SettingsOrb.restingTrim(for: .top, convex: true)
        let mid = Double((range.lowerBound + range.upperBound) / 2) * 2 * .pi
        let direction = CGPoint(x: cos(mid), y: sin(mid))
        // +along is along the bar; +across is deeper into it, away from the bezel.
        XCTAssertGreaterThan(direction.x * NotchEdge.top.alongDirection.x
                             + direction.y * NotchEdge.top.alongDirection.y, 0.5,
                             "the arc does not reach past the end of the bar")
        XCTAssertGreaterThan(direction.x * -NotchEdge.top.outward.x
                             + direction.y * -NotchEdge.top.outward.y, 0.5,
                             "the arc does not reach past the foot of the bar")
    }

    /// Which is the concave arrangement through half a circle, on every edge.
    func testHuggingFromOutsideIsTheSameRelationshipTurnedAround() {
        for edge in NotchEdge.allCases {
            let concave = SettingsOrb.restingTrim(for: edge).lowerBound
            let convex = SettingsOrb.restingTrim(for: edge, convex: true).lowerBound
            let turned = (concave + 0.5).truncatingRemainder(dividingBy: 1)
            XCTAssertEqual(convex, turned, accuracy: 0.0001, "\(edge)")
        }
    }

    /// Nothing about the ordinary notch moves.
    func testAnUnmergedNotchKeepsTheOrbWhereItWas() {
        let m = model(flush: false)
        XCTAssertEqual(m.orbAlong, m.shapeLength, accuracy: 0.001)
        XCTAssertEqual(m.orbInset, NotchLayout.orbInsetFromEdge, accuracy: 0.001)
    }
}

/// Nothing of the readings may fall inside the hardware's band, and the shape
/// should meet the screen's frame with a corner rather than a raw edge.
@MainActor
final class HardwareClearanceTests: XCTestCase {
    private func model(cells: Int = 4, style: NotchSurfaceStyle = .solid) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        // The solid style is the default here because `ImageRenderer` has no
        // desktop behind it to refract, so glass renders as very little. The
        // glass style still gets its own case: there the band is painted by a
        // layer of its own, so it can regress on its own too.
        model.surfaceStyle = style
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "S", usedFraction: 0.4)],
                             headlineID: "w")
        }
        model.adopt(screen: notched)
        return model
    }

    /// The bug this pins: the cells were *centred* in a shape that had been made
    /// deeper, rather than pushed past the band that made it deeper. They ended
    /// up 19pt from the top instead of 38, so the top of every ring was inside
    /// the hole — which is what "the notch is blocking the rings" looks like.
    func testTheHardwaresBandHoldsNothingButBlack() {
        assertTheBandHoldsNothingButBlack(model())
    }

    /// The glass surface paints the band with a layer of its own, so it can go
    /// wrong on its own: without it the cutout reads as a black rectangle set
    /// into a sheet of glass.
    ///
    /// What this proves is that the band is opaque black *on the glass path* —
    /// the glass path is rendered with the system material left out, because
    /// offscreen it draws either nothing or an opaque grey over its siblings.
    /// The band is ours; the material is the system's and is not testable here.
    func testTheHardwaresBandStaysBlackInTheGlassStyle() {
        assertTheBandHoldsNothingButBlack(model(style: .glass))
    }

    private func assertTheBandHoldsNothingButBlack(
        _ m: NotchViewModel, file: StaticString = #filePath, line: UInt = #line
    ) {
        let size = m.notchSize
        let renderer = ImageRenderer(
            content: NotchRootView(model: m).frame(width: m.panelSize.width,
                                                   height: m.panelSize.height)
                // The system material is not renderable offscreen; the band
                // over it is ours. See TASKS.md, "The hardware's band stays
                // black".
                .environment(\.codenotchHeadlessGlass, true)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage, let rep = NSBitmapImageRep(cgImage: image).cgImage
        else { return XCTFail("nothing rendered", file: file, line: line) }
        let bitmap = NSBitmapImageRep(cgImage: rep)

        // Only the hole is out of bounds. The band either side of it is where
        // the readings live now, so scanning the full width would fail on the
        // rings themselves. The panel is centred on the screen and so is the
        // hole, which is what puts the hole in the middle of the panel.
        let place = NotchPlacement(edge: .top, panelSize: m.panelSize)
        let holeCentre = m.panelSize.width / 2
        let hole = (holeCentre - realNotch.width / 2)...(holeCentre + realNotch.width / 2)
        for across in stride(from: CGFloat(1), to: realNotch.height, by: 2) {
            for along in stride(from: hole.lowerBound, to: hole.upperBound, by: 3) {
                let point = place.point(along: along, across: across)
                guard let colour = bitmap.colorAt(x: Int(point.x), y: Int(point.y)),
                      colour.alphaComponent > 0.5 else { continue }
                // Black is the notch itself. Anything else is a ring, a track
                // or a label drawn where the display has a hole in it.
                XCTAssertLessThan(
                    colour.brightnessComponent, 0.05,
                    "something is drawn inside the hardware notch at (\(along), \(across))",
                    file: file, line: line
                )
            }
        }
    }

    /// **The hardware's bottom edge is the bezel, as far as the readings are
    /// concerned.** So a ring sits exactly the frame's own margin from it —
    /// the same distance it sits from the screen edge on every other placement.
    ///
    /// Anything on top of that is padding twice: an earlier version added a
    /// deliberate gap as well, and the readings ended up adrift of the notch
    /// they are supposed to belong to.
    func testTheRingsSitTheFramesOwnMarginFromTheHardware() {
        let m = model()
        // Beside the hole rather than below it, so the margin that matters runs
        // across the bar — and it has to be the same above and below the ring,
        // or the strip reads as cramped on one face.
        XCTAssertEqual(m.contentInset, 0, accuracy: 0.001,
                       "the readings are still being pushed below the hardware")
        XCTAssertEqual(m.splitDrawnMargin * 2 + m.splitDrawnRing, m.splitDrawnDepth,
                       accuracy: 0.001,
                       "the ring is not centred in the depth of the bar")
        XCTAssertGreaterThanOrEqual(m.splitDrawnMargin, NotchLayout.splitRingMargin - 0.001,
                                    "the ring is closer to the bar's edge than the frame allows")
    }

    /// Which is the same margin the ring has from the bezel anywhere else.
    func testItIsTheSameMarginEveryOtherPlacementUses() {
        XCTAssertEqual(NotchLayout.ringMargin(for: .top),
                       NotchLayout.ringMargin(for: .right), accuracy: 0.001)
    }

    /// The shape meets the screen's frame with a small inverse corner, the way
    /// the hardware notch is moulded into the bezel rather than cut out of it.
    /// Small: enough to round the join, not enough to taper the bar.
    func testItMeetsTheScreensFrameWithACorner() throws {
        let m = model()
        let size = m.notchSize
        let place = NotchPlacement(edge: .top, panelSize: size)
        let shape = m.notchShape
        let path = shape.path(in: CGRect(origin: .zero, size: size))

        func span(at across: CGFloat) -> ClosedRange<CGFloat>? {
            let hits = stride(from: CGFloat(0), to: size.width, by: 1)
                .filter { path.contains(place.point(along: $0, across: across)) }
            guard let first = hits.first, let last = hits.last else { return nil }
            return first...last
        }
        // What the ear loses between the border and the row just below the
        // sweep is the sweep itself.
        let fillet = try XCTUnwrap(m.splitFilletDepth)
        XCTAssertGreaterThan(fillet, 0, "the ear meets the border square")
        guard let atFrame = span(at: 0.2), let below = span(at: fillet + 1) else {
            return XCTFail("no shape to measure")
        }
        XCTAssertLessThanOrEqual(atFrame.lowerBound, NotchRootView.bezelBleed,
                                 "the shape does not reach the screen's frame")
        XCTAssertEqual(below.lowerBound, try XCTUnwrap(m.splitFillet), accuracy: 2,
                       "the sweep into the screen's border is missing")

        // **And none of it is spent behind the bezel.** The shape is pushed
        // `bezelBleed` past the top of the screen so no wallpaper hairline
        // shows; a sweep started up there arrives on screen already part way
        // through its turn and reads as a tip cut off by the border rather
        // than one sitting on it. So that band is straight, and the sweep
        // begins at the first row anyone can see.
        guard let hiddenTop = span(at: 0.2),
              let hiddenFoot = span(at: NotchRootView.bezelBleed - 0.2) else {
            return XCTFail("nothing drawn behind the bezel")
        }
        XCTAssertEqual(hiddenTop.lowerBound, hiddenFoot.lowerBound, accuracy: 0.5,
                       "the sweep starts behind the bezel, so its tip is over the border")
        XCTAssertEqual(hiddenTop.upperBound, hiddenFoot.upperBound, accuracy: 0.5,
                       "the sweep starts behind the bezel, so its tip is over the border")

        // And it does start there, rather than lower down.
        guard let justBelow = span(at: NotchRootView.bezelBleed + 1) else {
            return XCTFail("nothing visible at the screen's edge")
        }
        XCTAssertGreaterThan(justBelow.lowerBound, hiddenFoot.lowerBound,
                             "the sweep has not begun by the first visible row")
    }
}

/// The bar should reserve no more room at its ends than it actually draws there.
@MainActor
final class BarEndMarginTests: XCTestCase {
    private func model(cells: Int = 4, screen: ScreenDescribing = notched) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: screen)
        return model
    }

    /// The bug: `shapeLength` reserves a full `curlRadius` at each end for the
    /// flares, and a flush bar draws only the small corner into the frame. The
    /// difference — some 56pt across the pair — became dead black either side of
    /// the readings, which is what made the top bar look so wide.
    func testItReservesOnlyWhatItDraws() {
        let m = model()
        let reserved = (m.shapeLength - m.bodyLength) / 2

        let size = m.notchSize
        let place = NotchPlacement(edge: .top, panelSize: size)
        // From the model, not the shape's defaults — measuring a shape the
        // view does not build is how several of these bugs stayed hidden.
        let shape = m.notchShape
        let path = shape.path(in: CGRect(origin: .zero, size: size))
        // Sampled down the straight part of the side, clear of the foot's
        // corner: what the ends reserve has to be what they draw there.
        let probe = m.notchDepth / 2
        let drawn = stride(from: CGFloat(0), to: size.width, by: 1)
            .first { path.contains(place.point(along: $0, across: probe)) } ?? -1

        XCTAssertEqual(reserved, drawn, accuracy: 3,
                       "the bar reserves \(reserved)pt at each end but draws \(drawn)pt")
    }

    /// Which reads, at the ends, as a margin in proportion to the readings
    /// rather than one that dwarfs them.
    func testTheMarginBesideTheFirstRingIsProportionate() {
        let m = model()
        let ringEdge = m.ringCenter(index: 0) - NotchLayout.ringDiameter / 2
        XCTAssertLessThan(ringEdge, NotchLayout.ringDiameter * 1.2,
                          "there is more black beside the first ring than there is ring")
    }

    /// Still symmetric — but about the hole, not about the bar's middle. With
    /// an odd count the left group carries the extra ring on purpose, so the
    /// ring *centres* no longer mirror each other. The margins do.
    ///
    /// One ring is left out: it makes a single ear, and the far end of the bar
    /// is the hole rather than a margin.
    func testTheEndsMatchEachOther() {
        for count in 2...5 {
            let m = model(cells: count)
            let radius = NotchLayout.ringDiameter * m.splitCellScale / 2
            XCTAssertEqual(m.ringCenter(index: 0) - radius,
                           m.shapeLength - (m.ringCenter(index: count - 1) + radius),
                           accuracy: 0.5, "\(count) cells")
        }
    }

    /// A notch that still has its flares keeps every point of the room they need.
    func testAFlaredNotchIsUnchanged() {
        let m = model(screen: plain)
        XCTAssertEqual((m.shapeLength - m.bodyLength) / 2, NotchLayout.curlRadius,
                       accuracy: 0.001)
    }
}

/// The handle answers where it is drawn, and not in the space around it.
@MainActor
final class OrbHitAccuracyTests: XCTestCase {
    private func model(flush: Bool = true) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        model.snapshots = (0..<4).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: flush ? notched : plain)
        return model
    }

    private func arcCentre(_ m: NotchViewModel) -> CGPoint {
        CGPoint(x: m.orbAlong + m.orbArcOffset.width, y: m.orbInset + m.orbArcOffset.height)
    }

    /// **Nothing answers beside the hardware, because nothing is drawn there.**
    ///
    /// You can reach the button itself.
    func testTheButtonAnswers() {
        let m = model()
        XCTAssertTrue(m.isOnOrbHandle(along: m.orbAlong, across: m.orbInset))
    }

    /// And the arc, which at rest is the only part of it you can see.
    func testTheArcAnswers() {
        let m = model()
        let centre = arcCentre(m)
        // The middle of the quadrant: out from its centre, the way the button went.
        let reach = hypot(m.orbAlong - centre.x, m.orbInset - centre.y)
        let mid = CGPoint(x: centre.x + m.orbArcRadius * (m.orbAlong - centre.x) / reach,
                          y: centre.y + m.orbArcRadius * (m.orbInset - centre.y) / reach)
        XCTAssertTrue(m.isOnOrbHandle(along: mid.x, across: mid.y),
                      "pointing at the arc does not reach the handle")
    }

    /// **But not the empty ground beside them.**
    ///
    /// The arc stays back on the bar's corner while the button hangs off it,
    /// and a *bounding box* around the pair takes in a good deal that is near
    /// neither — which is why the button used to appear well before the pointer
    /// got anywhere close to the arc. The box's own corners are the proof: a
    /// box test accepts them, and nothing is drawn within reach of either.
    func testTheCornersOfTheBoxBetweenThemDoNotAnswer() {
        let m = model()
        let points = m.orbHandlePoints
        guard points.count == 2 else { return XCTFail("expected an arc and a button") }
        let reach = m.orbHotZone / 2
        let box = CGRect(
            x: min(points[0].x, points[1].x) - reach,
            y: min(points[0].y, points[1].y) - reach,
            width: abs(points[0].x - points[1].x) + reach * 2,
            height: abs(points[0].y - points[1].y) + reach * 2
        )
        for corner in [CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.minY)] {
            XCTAssertFalse(
                m.isOnOrbHandle(along: corner.x, across: corner.y),
                "the handle answers at a corner of its own bounding box, where nothing is drawn"
            )
        }
    }

    /// And a ring keeps the clicks aimed at it. The hot zone used to be wider
    /// than the bar is deep, so it reached back over the readings.
    func testAClickOnARingIsNotSwallowedByTheHandle() {
        let m = model()
        for index in m.snapshots.indices {
            XCTAssertFalse(
                m.isOnOrbHandle(along: m.ringCenter(index: index), across: m.ringAcross),
                "ring \(index) is inside the settings handle's reach"
            )
        }
    }

    /// Nor anywhere back inside the bar.
    func testItDoesNotAnswerInsideTheBar() {
        let m = model()
        XCTAssertFalse(m.isOnOrbHandle(along: m.shapeLength / 2, across: m.notchDepth / 2))
    }

    /// A flared notch is reached exactly as it always was: one zone, on the orb.
    func testAFlaredNotchAnswersOnItsOrb() {
        let m = model(flush: false)
        XCTAssertTrue(m.isOnOrbHandle(along: m.orbAlong, across: m.orbInset))
        XCTAssertFalse(m.isOnOrbHandle(along: m.orbAlong + NotchLayout.orbHotZone,
                                       across: m.orbInset))
    }
}

/// The resting arc traces the bar's corner, so it must turn about the very
/// point the *drawn* corner turns about.
@MainActor
final class ArcConcentricityTests: XCTestCase {
    private func model() -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        model.snapshots = (0..<4).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: notched)
        return model
    }

    /// The arc this suite was written for is not drawn beside the hardware —
    /// see `OrbOnAFlushBarTests`. What is worth keeping is the *method*: the
    /// bug it caught was a curve placed by a formula that disagreed with the
    /// path, so the corner is measured off the path the app actually builds,
    /// with every input taken from the model rather than restated here.
    ///
    /// That is the whole failure mode of this redesign in one line. Four
    /// separate times the shape was wrong because the view worked out its own
    /// version of something the model already knew, and the tests passed
    /// because they asked the model.
    func testTheBarTurnsAtTheCornerTheModelChose() throws {
        let m = model()
        let size = m.notchSize
        let place = NotchPlacement(edge: .top, panelSize: size)
        let shape = m.notchShape
        let path = shape.path(in: CGRect(origin: .zero, size: size))

        // The leading bottom corner's centre, in the shape's own terms: past
        // the flare and its own radius along, and its radius up from the foot.
        let centre = CGPoint(x: try XCTUnwrap(m.splitFillet) + m.drawnCornerRadius,
                             y: m.notchDepth - m.drawnCornerRadius)

        // Down and to the left, which is the quadrant the corner turns through.
        for degrees in stride(from: 95.0, through: 175.0, by: 10.0) {
            let angle = degrees * .pi / 180
            var edge: CGFloat = -1
            var radius: CGFloat = 0
            while radius < 140 {
                let point = place.point(along: centre.x + cos(angle) * radius,
                                        across: centre.y + sin(angle) * radius)
                if path.contains(point) { edge = radius }
                radius += 0.25
            }
            XCTAssertEqual(
                edge, m.drawnCornerRadius, accuracy: 1.5,
                "at \(Int(degrees))° the bar's edge is \(edge)pt from the corner's centre, "
                    + "not the \(m.drawnCornerRadius)pt the model asked for"
            )
        }
    }
}

/// Opening should look like the notch *stretching*, not like one shape turning
/// into another.
@MainActor
final class ExpansionShapeTests: XCTestCase {
    /// Configured once, drawn into rects of every size: the shape does not
    /// depend on the rect, which is the property these tests are about.
    private func shape() -> SideNotchShape {
        let model = NotchViewModel()
        model.edge = .top
        model.adopt(screen: notched)
        return model.notchShape
    }

    /// How far the shape pulls in at its foot — which is its corner radius.
    private func cornerPullIn(width: CGFloat, depth: CGFloat) -> CGFloat {
        let size = CGSize(width: width, height: depth)
        let place = NotchPlacement(edge: .top, panelSize: size)
        let path = shape().path(in: CGRect(origin: .zero, size: size))

        func span(at across: CGFloat) -> ClosedRange<CGFloat>? {
            let hits = stride(from: CGFloat(0), to: width, by: 0.5)
                .filter { path.contains(place.point(along: $0, across: across)) }
            guard let first = hits.first, let last = hits.last else { return nil }
            return first...last
        }
        // The straight section — below the frame fillet, above the corner —
        // against the very bottom, where the corner has run its course. Taken
        // at the same depth from the foot every time, so the figures compare
        // even though neither is the corner's radius outright.
        guard let body = span(at: NotchLayout.bezelFillet + 2),
              let foot = span(at: depth - 0.25) else { return -1 }
        return ((foot.lowerBound - body.lowerBound) + (body.upperBound - foot.upperBound)) / 2
    }

    /// The corner is the same size at rest as it is open, so the shape stretches
    /// rather than un-rounding as it grows. Left to the frame it is clamped to
    /// half the depth, which at the hardware's own 38pt makes the resting shape
    /// very nearly a pill — and opening it then reads as a rounded tab turning
    /// into a bar.
    func testTheCornerIsTheSameSizeShutAsOpen() {
        let shut = cornerPullIn(width: realNotch.width, depth: realNotch.height)
        let open = cornerPullIn(width: 336.2, depth: 135.1)
        XCTAssertGreaterThan(shut, 0, "nothing measured shut")
        XCTAssertEqual(shut, open, accuracy: 1.5,
                       "the corner is \(shut)pt shut and \(open)pt open — the shape morphs")
    }

    /// And it stays that size the whole way, so no frame of the animation
    /// rounds off more than any other.
    func testTheCornerHoldsThroughTheWholeExpansion() {
        let reference = cornerPullIn(width: realNotch.width, depth: realNotch.height)
        for step in 1...6 {
            let t = CGFloat(step) / 6
            let corner = cornerPullIn(width: realNotch.width + (336.2 - realNotch.width) * t,
                                      depth: realNotch.height + (135.1 - realNotch.height) * t)
            XCTAssertEqual(corner, reference, accuracy: 1.5,
                           "the corner changes size \(Int(t * 100))% of the way open")
        }
    }

    /// The resting shape used to hide *inside* the hole, so its corners had to
    /// be at least as round as the hardware's or they showed as two nubs past
    /// the edge — which meant a pill, half the depth.
    ///
    /// It sits beside the hole now, in plain view, so the opposite constraint
    /// applies: a pill end is not what a Mac notch looks like. Apple's corner
    /// is a little under a third of the height, and the ears follow it.
    @MainActor
    func testTheRestingCornerFollowsApplesRatherThanRoundingToAPill() {
        let model = NotchViewModel()
        model.edge = .top
        model.adopt(screen: notched)
        XCTAssertEqual(model.drawnCornerRadius,
                       realNotch.height * NotchLayout.splitCornerFraction, accuracy: 0.001,
                       "the ears do not turn at the rate the cutout does")
        XCTAssertLessThan(model.drawnCornerRadius, realNotch.height / 2,
                          "the ends have rounded off into pills")
    }
}
