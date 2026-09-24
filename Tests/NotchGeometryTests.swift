import XCTest
import SwiftUI
@testable import Codenotch

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
    var displayIdentifier: String? = nil
}

final class NotchGeometryTests: XCTestCase {
    private let screen = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132)
    )

    func testPanelHugsTheRightEdgeAndIsVerticallyCentred() {
        let size = CGSize(width: 334, height: 484)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: size)
        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.001)
        // Centring is allowed to be half a point out: the frame is rounded to
        // whole points so the right-hand edge can be exact, and being flush
        // against the bezel matters where half a point of vertical drift does not.
        XCTAssertEqual(frame.midY, screen.frameValue.midY, accuracy: 0.5)
        XCTAssertEqual(frame.size, size)
    }

    func testPanelFollowsAScreenWithANonZeroOrigin() {
        let secondary = FakeScreen(
            frameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1440),
            visibleFrameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1415)
        )
        let frame = NotchGeometry.panelFrame(for: secondary, panelSize: CGSize(width: 334, height: 484))
        XCTAssertEqual(frame.maxX, 0, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 920, accuracy: 0.5)
    }

    func testAChosenDisplayWinsOverTheActiveOne() {
        let active = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                                displayIdentifier: "active")
        let chosen = FakeScreen(frameValue: CGRect(x: 100, y: 0, width: 100, height: 100),
                                visibleFrameValue: .zero, displayIdentifier: "chosen")

        let result = NotchGeometry.preferredScreen(
            from: [active, chosen], preference: .display("chosen"), activeScreen: active
        )

        XCTAssertEqual(result?.displayIdentifier, "chosen")
    }

    func testADisconnectedChoiceTemporarilyFallsBackToTheActiveDisplay() {
        let active = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                                displayIdentifier: "active")

        let result = NotchGeometry.preferredScreen(
            from: [active], preference: .display("missing"), activeScreen: active
        )

        XCTAssertEqual(result?.displayIdentifier, "active")
    }

    func testFollowActiveWindowUsesTheActiveDisplay() {
        let first = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                               displayIdentifier: "first")
        let active = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                                displayIdentifier: "active")

        let result = NotchGeometry.preferredScreen(
            from: [first, active], preference: .followActiveWindow, activeScreen: active
        )

        XCTAssertEqual(result?.displayIdentifier, "active")
    }
}

/// `alongOffset` is how a ⌥-drag on the pill (`NotchWindowController.dragged`)
/// nudges it off the centred default. These pin down the sign convention —
/// get it wrong and the pill runs away from the cursor instead of following
/// it — and the clamp that keeps a drag from pushing it off the screen.
final class PanelOffsetTests: XCTestCase {
    private let screen = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132)
    )

    @MainActor
    func testDraggingToTheTrailingEndKeepsTheSettingsHandleOnScreen() {
        let secondary = FakeScreen(
            frameValue: CGRect(x: -1800, y: -200, width: 1800, height: 1169),
            visibleFrameValue: CGRect(x: -1800, y: -200, width: 1800, height: 1132)
        )
        for display in [screen, secondary] {
            for edge in NotchEdge.allCases {
                for size in NotchSize.allCases {
                    let model = NotchViewModel()
                    model.edge = edge
                    model.sizeScale = size.scale
                    let frame = NotchGeometry.panelFrame(
                        for: display, panelSize: model.panelSize, edge: edge,
                        alongOffset: 10_000, slack: model.slack,
                        trailingExtent: model.trailingExtent
                    )
                    let handleEnd = model.slack
                        + (model.orbAlong + NotchLayout.orbHotZone / 2) * model.sizeScale
                    if edge.isVertical {
                        XCTAssertGreaterThanOrEqual(frame.maxY - handleEnd,
                                                    display.frameValue.minY - 0.5)
                    } else {
                        XCTAssertLessThanOrEqual(frame.minX + handleEnd,
                                                 display.frameValue.maxX + 0.5)
                    }
                }
            }
        }
    }

    @MainActor
    func testDraggingToTheLeadingEndKeepsTheMoveHandleOnScreen() {
        let secondary = FakeScreen(
            frameValue: CGRect(x: -1800, y: -200, width: 1800, height: 1169),
            visibleFrameValue: CGRect(x: -1800, y: -200, width: 1800, height: 1132)
        )
        for display in [screen, secondary] {
            for edge in NotchEdge.allCases {
                for size in NotchSize.allCases {
                    let model = NotchViewModel()
                    model.edge = edge
                    model.sizeScale = size.scale
                    let frame = NotchGeometry.panelFrame(
                        for: display, panelSize: model.panelSize, edge: edge,
                        alongOffset: -10_000, slack: model.slack,
                        leadingExtent: model.leadingExtent
                    )
                    let handleStart = model.slack
                        + (model.moveAlong - NotchLayout.orbHotZone / 2) * model.sizeScale
                    if edge.isVertical {
                        XCTAssertLessThanOrEqual(frame.maxY - handleStart,
                                                 display.frameValue.maxY + 0.5)
                    } else {
                        XCTAssertGreaterThanOrEqual(frame.minX + handleStart,
                                                    display.frameValue.minX - 0.5)
                    }
                }
            }
        }
    }

    func testZeroOffsetChangesNothing() {
        let size = CGSize(width: 334, height: 484)
        let centred = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right)
        let explicit = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right, alongOffset: 0)
        XCTAssertEqual(centred, explicit)
    }

    /// A positive offset on a side edge moves the pill *down* — the direction
    /// `NotchWindowController.dragged` feeds it in when the pointer moves
    /// down, since `NSEvent`'s raw delta and AppKit's y-grows-up frame origin
    /// disagree about which way is positive.
    func testPositiveOffsetMovesASideEdgePanelDown() {
        let size = CGSize(width: 334, height: 484)
        let centred = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right)
        let nudged = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right, alongOffset: 100)
        XCTAssertEqual(nudged.midY, centred.midY - 100, accuracy: 0.5)
        // Still flush against the right-hand bezel — only the along axis moved.
        XCTAssertEqual(nudged.maxX, centred.maxX, accuracy: 0.001)
    }

    /// A positive offset on a top/bottom edge moves the pill *right* — no sign
    /// flip needed there, since `NSEvent.deltaX` and AppKit's x already agree.
    func testPositiveOffsetMovesATopEdgePanelRight() {
        let size = CGSize(width: 484, height: 120)
        let centred = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .top)
        let nudged = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .top, alongOffset: 100)
        XCTAssertEqual(nudged.midX, centred.midX + 100, accuracy: 0.5)
        XCTAssertEqual(nudged.maxY, centred.maxY, accuracy: 0.001)
    }

    /// `slack` is the padding `panelSize` carries beyond the visible pill,
    /// reserved for a hover card that may not be open. Clamping by the full
    /// panel — as if that padding had to stay on screen too — left almost no
    /// room to drag on a panel sized for the worst-case card. Clamping by the
    /// pill's own extent instead should let it travel nearly the whole edge.
    func testAnExtremeOffsetKeepsTheVisiblePillOnScreenRatherThanThePadding() {
        let slack = 400.0
        let size = CGSize(width: 334, height: 900)   // mostly hover-card padding
        let frame = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: .right, alongOffset: 10_000, slack: slack
        )
        let pillTop = frame.maxY - slack
        let pillBottom = frame.minY + slack
        XCTAssertLessThanOrEqual(pillTop, screen.frameValue.maxY + 0.5)
        XCTAssertGreaterThanOrEqual(pillBottom, screen.frameValue.minY - 0.5)
    }

    /// Without `slack`'s allowance, the same drag would have clamped to
    /// keeping the *entire* padded panel on screen — which the real bug
    /// report was about: a handful of points of travel on a panel sized for
    /// four providers' worth of hover card.
    func testSlackWidensTheDraggableRangeBeyondClampingTheWholePanel() {
        let size = CGSize(width: 334, height: 900)
        let withoutSlack = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: .right, alongOffset: 10_000, slack: 0
        )
        let withSlack = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: .right, alongOffset: 10_000, slack: 400
        )
        XCTAssertLessThan(withSlack.minY, withoutSlack.minY)
    }
}

/// A hairline of wallpaper down the right-hand side is all it takes for the
/// notch to read as floating instead of welded to the bezel, and a fractional
/// panel frame is how that happens.
final class PanelEdgeTests: XCTestCase {
    private let screen = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132)
    )

    /// The real panel size is fractional — it is derived from the design
    /// frame's pixel ratios — which is exactly the case that used to leave a gap.
    func testAFractionalSizeStillLandsFlushOnTheEdge() {
        let fractional = CGSize(width: 334.3247863247863, height: 205.182905982906)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: fractional)
        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.0001)
    }

    func testTheFrameIsIntegral() {
        let frame = NotchGeometry.panelFrame(
            for: screen,
            panelSize: CGSize(width: 334.3247863247863, height: 205.182905982906)
        )
        for value in [frame.minX, frame.minY, frame.width, frame.height] {
            XCTAssertEqual(value, value.rounded(), "\(value) is not a whole point")
        }
    }

    /// Rounding must never make the panel narrower than its content.
    func testItNeverRoundsBelowTheRequestedSize() {
        let requested = CGSize(width: 334.325, height: 205.183)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: requested)
        XCTAssertGreaterThanOrEqual(frame.width, requested.width)
        XCTAssertGreaterThanOrEqual(frame.height, requested.height)
    }

    func testItStaysFlushOnAScreenWithANonZeroOrigin() {
        let secondary = FakeScreen(
            frameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1440),
            visibleFrameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1415)
        )
        let frame = NotchGeometry.panelFrame(
            for: secondary,
            panelSize: CGSize(width: 334.3247863247863, height: 205.182905982906)
        )
        XCTAssertEqual(frame.maxX, 0, accuracy: 0.0001)
    }
}

/// Use an offset monitor and reserve desktop space on every side so accidental
/// dependencies on the primary display or visibleFrame are caught together.
final class ScreenAnchorRegressionTests: XCTestCase {
    func testEveryEdgeIgnoresDesktopReservationsAtEveryDragPosition() {
        let full = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let shown = FakeScreen(frameValue: full,
                               visibleFrameValue: full.insetBy(dx: 90, dy: 70))
        let hidden = FakeScreen(frameValue: full, visibleFrameValue: full)
        for edge in NotchEdge.allCases {
            let size = NotchPlacement.panelSize(edge: edge, length: 800, depth: 300)
            for offset: CGFloat in [-10000, -230, 0, 310, 10000] {
                let frame = NotchGeometry.panelFrame(for: shown, panelSize: size,
                                                     edge: edge, alongOffset: offset, slack: 200)
                XCTAssertEqual(frame, NotchGeometry.panelFrame(for: hidden, panelSize: size,
                                                                edge: edge, alongOffset: offset, slack: 200))
                switch edge {
                case .left: XCTAssertEqual(frame.minX, full.minX)
                case .right: XCTAssertEqual(frame.maxX, full.maxX)
                case .top: XCTAssertEqual(frame.maxY, full.maxY)
                case .bottom: XCTAssertEqual(frame.minY, full.minY)
                }
            }
        }
    }

    @MainActor func testCornerTooltipsStayInsideTheVisiblePartOfThePanel() {
        for size in NotchSize.allCases {
            for edge in NotchEdge.allCases {
                let model = NotchViewModel()
                model.edge = edge
                model.sizeScale = size.scale
                let length: CGFloat = edge.isVertical ? 300 : NotchLayout.cardWidth
                let ring = model.slack + model.ringCenter(index: 0) * size.scale
                XCTAssertEqual(model.tooltipAlong(index: 0, length: length), ring)
                // Both ends of the screen: the ring remains on screen, while a
                // card centred on it would lose its heading or its right edge.
                for range in [(ring - 45)...(ring + 900), (ring - 900)...(ring + 45)] {
                    model.visibleAlongRange = range
                    let centre = model.tooltipAlong(index: 0, length: length)
                    XCTAssertGreaterThanOrEqual(centre - length / 2, range.lowerBound - 0.0001)
                    XCTAssertLessThanOrEqual(centre + length / 2, range.upperBound + 0.0001)
                    XCTAssertNotEqual(centre, ring)
                    XCTAssertLessThanOrEqual(abs(ring - centre), length / 2 - NotchLayout.tailHeight / 2)
                }
                model.visibleAlongRange = (ring - 900)...(ring + 900)
                XCTAssertEqual(model.tooltipAlong(index: 0, length: length), ring)
            }
        }
    }
}

/// The size choice reaches the screen in the notch's own measurements, never
/// in the tooltip's. These pin the seam between the two.
final class ScaledMeasurementTests: XCTestCase {
    /// A scaled panel is still a panel: it has to land flush on the bezel like
    /// any other, or a large notch floats a hairline off the edge.
    func testAScaledPanelStillLandsFlushOnTheEdge() {
        let screen = FakeScreen(frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1000),
                                visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1000))
        let frame = NotchGeometry.panelFrame(
            for: screen,
            panelSize: CGSize(width: 200, height: 750),
            edge: .right
        )

        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.001)
    }

    /// The notch's own end margin scales; the room reserved for the card does
    /// not. Scaling both would reserve space for a card that is never that big,
    /// and at the small end would reserve less than the card needs.
    func testSlackScalesTheNotchsMarginAndNotTheCards() {
        let cardBound = NotchLayout.slack(for: .right, maxCardHeight: 2000)
        XCTAssertEqual(NotchLayout.slack(for: .right, maxCardHeight: 2000, notchScale: 0.8),
                       cardBound,
                       "the card's half-extent was scaled with the notch")

        let marginBound = NotchLayout.slack(for: .right, maxCardHeight: 0)
        XCTAssertEqual(NotchLayout.slack(for: .right, maxCardHeight: 0, notchScale: 2),
                       marginBound * 2, accuracy: 0.001)
    }
}

/// The readings sit in the menu-bar strips either side of the hardware notch,
/// not under it.
///
/// Measured against the real hardware this was designed on: a 220 × 38 pt hole
/// in an 1800 pt display, leaving 790 pt of strip either side.
@MainActor
final class SplitAroundHardwareNotchTests: XCTestCase {
    private func model(cells: Int, notch: HardwareNotch? = HardwareNotch(width: 220, height: 38)) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.hardwareNotch = notch
        model.snapshots = (0..<cells).map {
            ProviderSnapshot(id: "p\($0)", displayName: "p\($0)", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        return model
    }

    func testItSplitsOnlyWhereThereIsAHoleToSplitAround() {
        XCTAssertTrue(model(cells: 4).splitsAroundHardwareNotch)
        XCTAssertFalse(model(cells: 4, notch: nil).splitsAroundHardwareNotch,
                       "a display with no notch has nothing to sit beside")
        let side = model(cells: 4)
        side.edge = .right
        XCTAssertFalse(side.splitsAroundHardwareNotch, "only the top edge meets the hardware")
    }

    /// The odd cell goes left, so three readings are two then one.
    func testTheOddCellGoesLeft() {
        XCTAssertEqual(model(cells: 3).splitLeftCount, 2)
        XCTAssertEqual(model(cells: 4).splitLeftCount, 2)
        XCTAssertEqual(model(cells: 5).splitLeftCount, 3)
    }

    /// The whole point: no ring centre may land inside the hole.
    func testNoRingIsDrawnInsideTheHole() {
        for count in 1...6 {
            let m = model(cells: count)
            let centres = m.snapshots.indices.map { m.ringCenter(index: $0) }
            let holeStart = centres[m.splitLeftCount - 1] + NotchLayout.ringDiameter * m.splitCellScale / 2
            let holeEnd = holeStart + m.splitGap
            for (index, centre) in centres.enumerated() where index >= m.splitLeftCount {
                XCTAssertGreaterThanOrEqual(centre, holeEnd - 0.5,
                    "cell \(index) of \(count) is drawn inside the hardware notch")
            }
        }
    }

    /// The gap between the last left cell and the first right cell is the
    /// hole's own width, so the two groups hug it rather than float.
    func testTheGapIsTheHardwareWidth() {
        let m = model(cells: 4)
        let lastLeft = m.ringCenter(index: m.splitLeftCount - 1)
        let firstRight = m.ringCenter(index: m.splitLeftCount)
        let along = NotchLayout.cellAlong(for: .top) * m.splitCellScale
        XCTAssertEqual(firstRight - lastLeft - along, m.splitGap, accuracy: 0.5)
        XCTAssertEqual(m.splitGap, 220 + 2 * NotchLayout.splitHoleClearance, accuracy: 0.5,
                       "the gap is the hardware plus clearance at each end")
    }

    /// The bug this was reported with: one ring, and half of it drawn behind
    /// the hardware.
    ///
    /// The panel is centred on the screen and the hole is centred in the
    /// hardware, so the gap has to sit in the middle of the shape whatever the
    /// counts are. With an uneven split — and one ring is the most uneven there
    /// is — an asymmetric layout slides the shape's middle off the hardware's
    /// and the innermost rings end up under the cutout.
    func testTheHoleStaysCentredWhateverTheCount() {
        for count in 1...6 {
            let m = model(cells: count)
            let shape = m.shapeLength(cellCount: count)
            let holeStart = m.ringCenter(index: m.splitLeftCount - 1)
                + NotchLayout.cellAlong(for: .top) * m.splitCellScale / 2
            let holeMiddle = holeStart + m.splitGap / 2
            XCTAssertEqual(holeMiddle - m.splitShift, shape / 2, accuracy: 1.0,
                "with \(count) ring(s) the hole misses the hardware by "
                + "\(holeMiddle - m.splitShift - shape / 2)pt")
        }
    }

    /// Each side is exactly its own rings wide — no empty bar on the short
    /// side, which is what made a single ring sit in a shape twice the width
    /// it needed.
    func testEachSideHugsItsOwnRings() {
        for count in 1...6 {
            let m = model(cells: count)
            let along = NotchLayout.cellAlong(for: .top) * m.splitCellScale
            let w = m.splitWidths(cellCount: count)
            let leftCount = m.splitLeftCount, rightCount = count - m.splitLeftCount
            func expected(_ n: Int) -> CGFloat {
                n > 0 ? CGFloat(n) * along + CGFloat(n - 1) * m.splitCellSpacing : 0
            }
            XCTAssertEqual(w.left, expected(leftCount), accuracy: 0.5)
            XCTAssertEqual(w.right, expected(rightCount), accuracy: 0.5)
        }
        // One ring: no bar at all on the empty side.
        XCTAssertEqual(model(cells: 1).splitWidths(cellCount: 1).right, 0, accuracy: 0.01)
    }

    /// The shift has to reach the panel, not just the model.
    ///
    /// It was computed correctly and then applied to `notchLeadingInset`, which
    /// nothing in `Sources` reads — the shape is placed by `.position`. So the
    /// maths was right and the rings were still drawn under the cutout. This
    /// asserts the hole lands on the hardware in *panel* coordinates, which is
    /// the only place it matters.
    func testTheHoleLandsOnTheHardwareInPanelCoordinates() {
        for count in 1...6 {
            let m = model(cells: count)
            let panel = m.panelSize
            // Where the shape's gap ends up once the shift has moved the shape.
            let shapeCentre = panel.width / 2 - m.splitShift * m.sizeScale
            let shapeStart = shapeCentre - m.shapeLength * m.sizeScale / 2
            let gapStart = shapeStart
                + (m.ringCenter(index: m.splitLeftCount - 1)
                   + NotchLayout.cellAlong(for: .top) * m.splitCellScale / 2) * m.sizeScale
            let gapCentre = gapStart + m.splitGap * m.sizeScale / 2
            XCTAssertEqual(gapCentre, panel.width / 2, accuracy: 1.0,
                "with \(count) ring(s) the hardware sits \(gapCentre - panel.width / 2)pt "
                + "from the gap, so rings are drawn behind it")
        }
    }

    /// An even count needs no shift; an odd one is pushed back by half the
    /// difference so the gap still lands on the hardware.
    func testTheShiftOnlyExistsForAnUnevenSplit() {
        XCTAssertEqual(model(cells: 4).splitShift, 0, accuracy: 0.01)
        XCTAssertEqual(model(cells: 6).splitShift, 0, accuracy: 0.01)
        XCTAssertGreaterThan(model(cells: 1).splitShift, 0)
        XCTAssertGreaterThan(model(cells: 3).splitShift, 0)
    }

    /// The hole is hardware: it does not widen because someone chose a bigger
    /// notch. `splitGap` is divided by the scale that is applied downstream.
    func testTheHoleDoesNotGrowWithTheSizeSetting() {
        let m = model(cells: 4)
        for scale: CGFloat in [0.8, 1.0, 1.4] {
            m.sizeScale = scale
            XCTAssertEqual(m.splitGap * scale, 220 + 2 * NotchLayout.splitHoleClearance,
                           accuracy: 0.5, "the gap changed width at size \(scale)")
            _ = scale
        }
    }

    /// A ring plus its clearance has to fit the strip — at every size setting.
    ///
    /// The bar is the hardware's height and cannot grow, so a ring that
    /// followed the size preference simply overflowed it. Everything in this
    /// placement is held at its drawn size instead.
    /// The ring always fits the bar, and the bar never sits above the
    /// hardware's bottom edge.
    func testTheRingFitsTheBarAtEverySize() {
        let m = model(cells: 4)
        for scale: CGFloat in [0.8, 1.0, 1.2, 1.4] {
            m.sizeScale = scale
            let depth = m.splitDrawnDepth
            let ring = NotchLayout.ringDiameter * m.splitCellScale * scale
            XCTAssertGreaterThanOrEqual(depth, 38 - 0.01,
                "at size \(scale) the bar is \(depth)pt, shallower than the 38pt hardware")
            XCTAssertLessThanOrEqual(ring + 2 * NotchLayout.splitRingMargin, depth + 0.01,
                "at size \(scale) a \(ring)pt ring overflows a \(depth)pt bar")
            XCTAssertLessThanOrEqual(ring, NotchLayout.ringDiameter + 0.01,
                "at size \(scale) the ring is drawn larger than the design ring")
        }
        XCTAssertEqual(model(cells: 4, notch: nil).splitCellScale, 1,
                       "nothing shrinks where there is no bar to fit")
    }

    /// The setting has to do something in both directions.
    func testTheSizeSettingChangesTheRing() {
        let m = model(cells: 4)
        func ring(_ scale: CGFloat) -> CGFloat {
            m.sizeScale = scale
            return NotchLayout.ringDiameter * m.splitCellScale * scale
        }
        XCTAssertLessThan(ring(0.8), ring(1.0), "a smaller size drew the same ring")
        XCTAssertGreaterThan(ring(1.4), ring(1.0), "a larger size drew the same ring")
    }

    /// All four sides of the ring get the same clearance, at every size.
    ///
    /// They were separate constants — 4pt above and below, 8pt at the ends —
    /// so they drifted the moment the size moved: at 1.4 the ring is capped at
    /// the design ring in a deeper bar, leaving 4.5pt vertically against 11pt
    /// horizontally. The ends take the vertical margin now, by construction.
    func testThePaddingIsTheSameOnEverySide() {
        let m = model(cells: 4)
        for scale: CGFloat in [0.75, 1.0, 1.2, 1.4] {
            m.sizeScale = scale
            let above = m.splitDrawnMargin
            // What is actually clear beside the ring, once the rounded corner
            // has cut into the side at the ring's lowest point.
            let clearAtTheEnd = m.splitEndPad * scale - m.splitCornerIntrusion
            XCTAssertEqual(clearAtTheEnd, above, accuracy: 0.01,
                "at size \(scale): \(above)pt above and below, but only "
                + "\(clearAtTheEnd)pt clear at the end once the corner cuts in")
            XCTAssertGreaterThan(above, 0, "at size \(scale) the ring touches the bar's edge")
        }
    }

    /// The settings orb hangs off the bar's corner, not off thin air.
    ///
    /// Reported as a stray curve floating below the notch. `orbInset` measured
    /// from `bodyDepth` — the stacked layout's depth, about 30pt deeper than
    /// the bar beside the hardware — so the orb was placed well below a bar
    /// that had shrunk under it.
    func testTheOrbIsSizedAndPlacedAgainstTheBar() {
        for scale: CGFloat in [0.8, 1.0, 1.25] {
            let m = model(cells: 4)
            m.sizeScale = scale
            // The orb hangs off the corner by its own gap plus its own radius,
            // so shrinking it pulls it back in — the arc ends up tucked against
            // the bar rather than adrift below it.
            let hang = m.orbInset - m.splitDrawnDepth / scale
            XCTAssertGreaterThan(hang, 0, "at \(scale) the orb sits inside the bar")
            XCTAssertLessThan(hang, m.splitDrawnDepth / scale / 2,
                              "at \(scale) the orb hangs further below the bar than "
                              + "half its depth")
        }
        XCTAssertEqual(model(cells: 4, notch: nil).orbScale, 1, accuracy: 0.001,
                       "everywhere else it keeps the size it was drawn at")
    }

    /// The corner really does cut in, so the end has to be padded for it.
    ///
    /// Reported as the left side looking cramped while the numbers said every
    /// side was equal: the margin was equal, the *visible* clearance was not,
    /// because the ring sits low enough to fall inside the corner's curve.
    func testTheCornerIntrudesOnTheEnd() {
        let m = model(cells: 4)
        m.sizeScale = 1.0
        // Small, and smaller since the corner came down to a fifth of the
        // depth — but a ring sits low enough to fall inside what is left of
        // the curve, so the end still has to be padded for it.
        XCTAssertGreaterThan(m.splitCornerIntrusion, 0.5,
                             "the corner should measurably cut into the side")
        XCTAssertLessThan(m.splitCornerIntrusion, m.drawnCornerRadius,
                          "it cannot cut in further than the corner is deep")
        XCTAssertGreaterThan(m.splitEndPad * 1.0, m.splitDrawnMargin,
                             "the end must be padded beyond the bare margin")
    }

    /// The corner must not tighten while the bar stays the same depth.
    ///
    /// Below the default size the bar is floored at the hardware's 38pt, but
    /// the corner and the bezel fillet were still scaled by the raw setting —
    /// so at 75% the curve pulled in against a bar that had not moved, and
    /// stopped matching the cutout beside it.
    func testTheCurveTracksTheBarNotTheSetting() {
        let m = model(cells: 4)
        func drawn(_ scale: CGFloat) -> (corner: CGFloat, fillet: CGFloat, depth: CGFloat) {
            m.sizeScale = scale
            return (m.drawnCornerRadius * scale, m.flare * scale, m.splitDrawnDepth)
        }
        // **Nothing moves with the setting.** The cutout does not resize, so
        // neither does the thing drawn as it: depth, corner and sweep all come
        // out identical in drawn points at every size.
        let small = drawn(0.75), normal = drawn(1.0), large = drawn(1.4)
        for (name, it) in [("0.75", small), ("1.4", large)] {
            XCTAssertEqual(it.depth, normal.depth, accuracy: 0.01,
                           "the bar's depth moved at \(name)")
            XCTAssertEqual(it.corner, normal.corner, accuracy: 0.01,
                           "the corner moved at \(name)")
            XCTAssertEqual(it.fillet, normal.fillet, accuracy: 0.01,
                           "the sweep moved at \(name)")
        }
        XCTAssertEqual(normal.depth, 38, accuracy: 0.01,
                       "the bar is not the hardware's depth")
    }

    /// The hole is the one thing that cannot move: it is a cutout in a screen.
    func testTheHoleIsFixedWhateverTheSize() {
        let m = model(cells: 4)
        for scale: CGFloat in [0.8, 1.0, 1.4] {
            m.sizeScale = scale
            XCTAssertEqual(m.splitGap * scale, 220 + 2 * NotchLayout.splitHoleClearance,
                           accuracy: 0.5, "the hole moved at size \(scale)")
        }
    }

    /// Open or folded, what you can *see* of the bar is the hardware's depth.
    ///
    /// The drawn depth is two points more, because the shape is pushed that far
    /// past the top of the screen so no wallpaper hairline shows at the bezel.
    /// Measuring the frame rather than the visible part is what left the bar
    /// ending two points above the hardware's bottom edge.
    func testWhatYouSeeIsTheHardwareDepth() {
        let m = model(cells: 4)
        m.isExpanded = true
        XCTAssertEqual(m.notchDepth * m.sizeScale - NotchRootView.bezelBleed,
                       m.splitDrawnDepth, accuracy: 0.1, "visible depth is wrong when open")
        // And folded it is the same: never deeper than the cutout.
        m.isExpanded = false
        XCTAssertEqual(m.notchDepth * m.sizeScale - NotchRootView.bezelBleed,
                       m.splitDrawnDepth, accuracy: 0.1, "visible depth is wrong when folded")
    }
}

/// Prints the shape the split layout actually produces, so the numbers in a
/// design conversation are measured rather than estimated.
@MainActor
final class SplitLayoutReportTests: XCTestCase {
    func testReportTheShape() {
        for (count, scale) in [(5, 0.75), (5, 0.9), (5, 1.0), (5, 1.2), (5, 1.4)] {
            let m = NotchViewModel()
            m.edge = .top
            m.sizeScale = CGFloat(scale)
            m.hardwareNotch = HardwareNotch(width: 220, height: 38)
            m.snapshots = (0..<count).map {
                ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                                 fidelity: .official, status: .ok, windows: [])
            }
            let w = m.splitWidths(cellCount: count)
            let ring = NotchLayout.cellAlong(for: .top) * m.splitCellScale
            print(String(format:
                "  size %.2f: bar %.0f x %.0f  ring %.0f  pad all sides %.1f  between %.1f",
                scale,
                m.shapeLength(cellCount: count) * m.sizeScale,
                m.notchDepth * m.sizeScale - NotchRootView.bezelBleed,
                m.splitDrawnRing,
                m.splitDrawnMargin,
                m.splitCellSpacing * m.sizeScale))
            _ = w
        }
    }
}

/// Where the rings actually land on the *screen*, against the real hole.
///
/// Every earlier attempt at this reasoned in model space and was wrong for a
/// reason model space could not show: the shift was applied to a property
/// nothing reads. This walks the whole chain — panel frame, placement, scale —
/// and compares against the hardware's own rect.
@MainActor
final class SplitOnScreenTests: XCTestCase {
    private struct NotchedScreen: ScreenDescribing {
        var frameValue = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var visibleFrameValue = CGRect(x: 0, y: 56, width: 1800, height: 1074)
        var hardwareNotch: HardwareNotch? = HardwareNotch(width: 220, height: 38)
        var displayIdentifier: String? = nil
    }

    private static let mac = NotchedScreen()

    /// The view and the geometry must agree on where cell 0 starts and how far
    /// apart cells sit.
    ///
    /// This is the one every other test missed. They all asked `ringCenter`,
    /// which was right; the view padded by `padStart` (22.5pt) and spaced by
    /// `cellSpacing` (31pt) while the geometry used 8pt and 12pt. The shape was
    /// placed by one set of numbers and the rings drawn at another, so they sat
    /// on the cutout no matter how carefully the shape was positioned.
    func testTheViewAndTheGeometryAgree() {
        for count in 1...5 {
            let m = NotchViewModel()
            m.edge = .top
            m.adopt(screen: Self.mac)
            m.snapshots = (0..<count).map {
                ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                                 fidelity: .official, status: .ok, windows: [])
            }
            let along = NotchLayout.cellAlong(for: .top) * m.splitCellScale
            // What the view draws: leading padding, then a run of cells.
            XCTAssertEqual(m.ringCenter(index: 0), m.cellsLeadIn + along / 2, accuracy: 0.01,
                           "cell 0 is not drawn where the geometry places it")
            if count > 1, m.splitLeftCount > 1 {
                XCTAssertEqual(m.ringCenter(index: 1) - m.ringCenter(index: 0),
                               along + m.drawnCellSpacing, accuracy: 0.01,
                               "the view's spacing is not the geometry's")
            }
        }
    }

    /// Every ring has to fit inside the shape that clips it.
    ///
    /// The last ring was drawn 24pt beyond the shape's end and `.clipShape` cut
    /// it in half. Nothing caught it because the overflow was added by the view
    /// — an `HStack`'s spacing lands either side of the gap Spacer too — while
    /// every assertion asked the geometry, which knew nothing about it.
    func testNoRingIsClippedByTheShape() {
        for count in 1...6 {
            let m = NotchViewModel()
            m.edge = .top
            m.adopt(screen: Self.mac)
            m.snapshots = (0..<count).map {
                ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                                 fidelity: .official, status: .ok, windows: [])
            }
            let half = NotchLayout.cellAlong(for: .top) * m.splitCellScale / 2
            let last = try! XCTUnwrap(m.snapshots.indices.last)
            XCTAssertLessThanOrEqual(m.ringCenter(index: last) + half, m.shapeLength,
                "with \(count) ring(s) the last ring ends at "
                + "\(m.ringCenter(index: last) + half)pt in a \(m.shapeLength)pt shape")
            XCTAssertGreaterThanOrEqual(m.ringCenter(index: 0) - half, 0,
                "with \(count) ring(s) the first ring starts before the shape does")
        }
    }

    func testRingsLandBesideTheHoleNotUnderIt() {
        // The hole, in screen x: centred, 220 wide.
        let holeMin = 1800.0 / 2 - 110, holeMax = 1800.0 / 2 + 110
        for count in 1...5 {
            let m = NotchViewModel()
            m.edge = .top
            m.adopt(screen: Self.mac)
            m.snapshots = (0..<count).map {
                ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                                 fidelity: .official, status: .ok, windows: [])
            }
            m.isExpanded = true
            let panel = NotchGeometry.panelFrame(for: Self.mac, panelSize: m.panelSize, edge: .top)
            let place = NotchPlacement(edge: .top, panelSize: panel.size)
            let shapeCentreX = place.point(
                along: panel.width / 2 - m.splitShift * m.sizeScale,
                across: m.notchDepth / 2).x
            let shapeStartX = shapeCentreX - m.shapeLength * m.sizeScale / 2
            let ringHalf = NotchLayout.cellAlong(for: .top) * m.splitCellScale * m.sizeScale / 2

            for index in m.snapshots.indices {
                let cx = panel.minX + shapeStartX + m.ringCenter(index: index) * m.sizeScale
                // Not merely clear of the hole: clear of its rounded corners
                // too, which curve in from the reported width.
                //
                // A point of slack, because the panel's frame is rounded to
                // whole points and the shape is centred inside it — between
                // them that is up to half a point of drift either way, and the
                // clearance lands exactly on the limit at some ring counts.
                let need = NotchLayout.splitHoleClearance - 1
                let clearLeft = holeMin - (cx + ringHalf)
                let clearRight = (cx - ringHalf) - holeMax
                XCTAssertTrue(clearLeft >= need || clearRight >= need,
                    "with \(count) ring(s), ring \(index) spans "
                    + "\(Int(cx - ringHalf))–\(Int(cx + ringHalf)), the hole is "
                    + "\(Int(holeMin))–\(Int(holeMax)), clearance "
                    + "\(Int(max(clearLeft, clearRight)))pt")
            }
        }
    }
}

/// The shape has to receive what the model worked out.
///
/// `SideNotchShape` hardcoded a 10.5pt fillet for any joined shape and clamped
/// the corner to half the hardware's height, and the view never passed either —
/// so every adjustment the model made to the curve was silently discarded.
@MainActor
final class SplitShapeInputTests: XCTestCase {
    private func model(_ scale: CGFloat) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.hardwareNotch = HardwareNotch(width: 220, height: 38)
        m.sizeScale = scale
        // Open: the sweep into the screen's edge belongs to the ears, and
        // folded there are none — see `RestingShapeMatchesTheCutoutTests`.
        m.isExpanded = true
        m.snapshots = (0..<4).map {
            ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        return m
    }

    func testTheShapeIsGivenTheModelsCurve() {
        let m = model(1.0)
        let shape = m.notchShape

        XCTAssertEqual(shape.cornerRadius, 38 * NotchLayout.splitCornerFraction, accuracy: 0.01,
                       "the corner the model chose is not the one the shape draws")
        XCTAssertEqual(try XCTUnwrap(shape.filletDepth),
                       38 * NotchLayout.splitFilletFraction, accuracy: 0.01,
                       "the sweep into the screen's edge is not the depth chosen")
        XCTAssertEqual(try XCTUnwrap(shape.filletRadius),
                       38 * NotchLayout.splitFilletFraction * NotchLayout.splitFilletWidth,
                       accuracy: 0.01, "nor the length")
        // A quarter circle at `splitFilletWidth` 1. The stretch is there if the
        // sweep ever has to be flattened without getting deeper, and drawing a
        // circle is what it does when it is not asked to.
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(shape.filletRadius),
                                    try XCTUnwrap(shape.filletDepth),
                                    "the sweep is deeper than it is long")
        XCTAssertEqual(shape.filletRamp, NotchLayout.splitFilletRamp, accuracy: 0.001,
                       "the sweep is not drawn with its bend ramped in")
        XCTAssertEqual(shape.cornerRadius, 38 * NotchLayout.splitCornerFraction,
                       accuracy: 0.01, "the corner is not the one chosen")

    }

    /// Off a notched top edge the shape keeps its own defaults.
    func testAPlainEdgeGetsNoOverride() {
        let m = NotchViewModel()
        m.edge = .right
        XCTAssertNil(m.splitFillet)
        XCTAssertFalse(m.splitsAroundHardwareNotch)
    }

    /// **The ear sweeps into the screen's border**, at every size.
    ///
    /// Both numbers, because they have to agree: `flare` is what the *sizing*
    /// reserves at each end and `splitFillet` is what the *shape* draws there.
    /// Let them disagree and the curve is taken out of the straight body, and
    /// the outermost ring hangs over it.
    func testTheEarSweepsIntoTheScreensBorder() throws {
        for scale: CGFloat in [0.75, 1.0, 1.4] {
            let m = model(scale)
            let fillet = try XCTUnwrap(m.splitFillet)
            let depth = try XCTUnwrap(m.splitFilletDepth)
            XCTAssertGreaterThan(fillet, 0, "the ear meets the border square at \(scale)")
            XCTAssertEqual(m.flare, fillet, accuracy: 0.01,
                           "at size \(scale) the sizing does not reserve the sweep it draws")
            XCTAssertGreaterThan(fillet, depth,
                                 "at size \(scale) the sweep is no wider than it is deep")
            // It shares the depth with the corner at the foot and has to leave
            // some straight side between them.
            let side = m.notchDepth - depth - m.drawnCornerRadius
            XCTAssertGreaterThanOrEqual(side, 1,
                                        "at size \(scale) the sweep and the corner leave "
                                        + "\(side)pt of straight side")
        }
    }

    /// **The turns are continuous curves, not arcs.**
    ///
    /// An arc meets the straight it joins at the right angle and the wrong
    /// curvature — none along the straight, all of it the instant the arc
    /// begins — and the eye reads that jump as a kink. It is what "the edge
    /// curve feels stiff" was.
    ///
    /// **The corner is a circular arc**, which is what the cutout's is.
    ///
    /// Fitted over the whole sweep of a render of the real thing: an arc of
    /// radius 0.351 of the notch's depth, to within 0.18px. The fit prefers it
    /// over every squircled or curvature-ramped alternative, and two attempts
    /// at something cleverer here both came back as "stiff" — a single cubic
    /// that matches a target outline gets the curvature at the joins wrong,
    /// and the eye reads that jump as a kink whatever the outline does.
    func testTheCornerIsACircularArc() throws {
        let m = model(1.0)
        let r = m.drawnCornerRadius
        let size = m.notchSize
        let place = NotchPlacement(edge: .top, panelSize: size)
        let shape = m.notchShape
        let path = shape.path(in: CGRect(origin: .zero, size: size))

        // `along` in from the end, at the row where a circular corner would
        // have pulled in by the matching sagitta.
        let inset = r * 0.15
        let arc = r - (r * r - (r - inset) * (r - inset)).squareRoot()
        // Measured in from where the *straight* side starts, past the join
        // into the screen's edge — otherwise this samples the join instead.
        let from = try XCTUnwrap(m.splitFillet) + inset
        let across = stride(from: m.notchDepth, to: 0, by: -0.05)
            .first { path.contains(place.point(along: from, across: $0)) }
        let foot = try XCTUnwrap(across, "nothing drawn at the corner")
        let pulledIn = m.notchDepth - foot
        XCTAssertEqual(pulledIn, arc, accuracy: 0.35,
                       "\(inset)pt in, the foot has pulled back \(pulledIn)pt where an "
                       + "arc of this radius pulls back \(arc)pt — not a circle")
    }

    /// The corner turns at the hardware's rate, and holds there at every size.
    func testTheCornerIsAFractionOfTheHardware() {
        let m = model(1.0)
        XCTAssertEqual(m.drawnCornerRadius, 38 * NotchLayout.splitCornerFraction, accuracy: 0.01)
        for scale: CGFloat in [0.75, 1.4] {
            XCTAssertEqual(model(scale).drawnCornerRadius * scale, m.drawnCornerRadius,
                           accuracy: 0.01,
                           "the corner moved at \(scale) while the bar held at 38pt")
        }
    }

    /// And so does everything hung off it — the settings arc swung outward
    /// about twice as fast as the notch when the bar was allowed to deepen.
    ///
    /// At and above 1, where the bar is the cutout's. Below it the rings shrink
    /// inside it on purpose, and the orb is sized to a ring, so it shrinks too.
    func testTheOrbHoldsItsPlaceAtEverySize() {
        let m = model(1.0)
        let offset = m.orbAlong - m.cornerCentreAlong
        for scale: CGFloat in [1.0, 1.4, 2.0] {
            let other = model(scale)
            XCTAssertEqual((other.orbAlong - other.cornerCentreAlong) * scale, offset,
                           accuracy: 0.01,
                           "at \(scale) the orb sits a different distance off the corner")
        }
    }
}

/// Folded away, the shape has to *be* the cutout — same width at every depth,
/// so there is nothing of it to see inside the hole.
@MainActor
final class RestingShapeMatchesTheCutoutTests: XCTestCase {
    private func model() -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.snapshots = (0..<4).map {
            ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        m.hardwareNotch = HardwareNotch(width: 220, height: 38)
        m.isExpanded = false
        return m
    }

    func testTheRestingShapeHasNoSweepIntoTheBezel() {
        let m = model()
        // What the shape is *drawn* with. The sizing keeps the open value
        // throughout — the window has to hold the open notch, and a panel
        // built to the folded one is 38pt too narrow for it.
        XCTAssertEqual(m.drawnFilletDepth, 0, "the resting tab tapers inside the hole")
        XCTAssertEqual(m.drawnFillet, 0, "the resting tab tapers inside the hole")
        XCTAssertEqual(m.notchShape.filletDepth, 0, "the shape was given a sweep at rest")
        XCTAssertGreaterThan(m.splitFilletDepth ?? 0, 0,
                             "the sizing folded with the shape, which is the bug that "
                             + "put the arc and the tooltip 19pt out after an edge change")

        m.isExpanded = true
        XCTAssertGreaterThan(m.drawnFilletDepth ?? 0, 0,
                             "the ears lost their sweep into the screen's border")
    }

    /// **The panel does not shrink when the notch folds.**
    ///
    /// A relocate taken while the notch is shut — which is exactly what an
    /// edge change does — built a window 38pt too narrow for the open notch.
    /// The shape centres itself in its panel, so it landed 19pt off the arc
    /// and the tooltip, both placed from `slack`. Adjusting the size relocated
    /// and put it right, which is how it was spotted.
    func testThePanelIsTheSameSizeFoldedAsOpen() {
        let m = model()
        m.screenSize = CGSize(width: 1800, height: 1169)
        m.isExpanded = false
        let shut = m.panelSize(cellCount: 4)
        m.isExpanded = true
        let open = m.panelSize(cellCount: 4)
        XCTAssertEqual(shut.width, open.width, accuracy: 0.01,
                       "the panel is \(open.width - shut.width)pt narrower folded, so the "
                       + "shape will sit \((open.width - shut.width) / 2)pt off everything "
                       + "placed from slack until the next relocate")
        XCTAssertEqual(shut.height, open.height, accuracy: 0.01)
    }

    /// Straight-sided from the bezel down to its corners — no taper anywhere —
    /// and the cutout's own width, so opening it widens the hardware rather
    /// than growing a tab out of the middle of it.
    func testItIsStraightSidedAndTheCutoutsWidth() {
        let m = model()
        let size = CGSize(width: m.notchLength, height: m.notchDepth)
        let place = NotchPlacement(edge: .top, panelSize: size)
        let path = m.notchShape.path(in: CGRect(origin: .zero, size: size))

        func span(at across: CGFloat) -> ClosedRange<CGFloat>? {
            let hits = stride(from: CGFloat(0), to: size.width, by: 0.5)
                .filter { path.contains(place.point(along: $0, across: across)) }
            guard let first = hits.first, let last = hits.last else { return nil }
            return first...last
        }
        // Down to where its own corners begin, which the cutout has too.
        let straight = m.notchDepth - m.drawnCornerRadius - 1
        guard let atBezel = span(at: 0.5), let low = span(at: straight) else {
            return XCTFail("no resting shape to measure")
        }
        XCTAssertEqual(atBezel.lowerBound, low.lowerBound, accuracy: 1,
                       "the resting tab is narrower below the bezel than at it")
        XCTAssertEqual(atBezel.upperBound, low.upperBound, accuracy: 1,
                       "the resting tab is narrower below the bezel than at it")
        XCTAssertEqual(atBezel.upperBound - atBezel.lowerBound, 220, accuracy: 2,
                       "the resting tab is not the cutout's width")

        // And nothing of it reaches below the hole.
        XCTAssertLessThanOrEqual(m.notchDepth - NotchRootView.bezelBleed - 38, 0.01,
                                 "the folded notch hangs below the cutout")
    }
}

/// The fold is a morph, not a swap: everything that differs between the folded
/// and open shapes has to be carried by the animation.
@MainActor
final class FoldMorphTests: XCTestCase {
    private func model(_ open: Bool) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.snapshots = (0..<4).map {
            ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        m.hardwareNotch = HardwareNotch(width: 220, height: 38)
        m.isExpanded = open
        return m
    }

    /// **Every number that changes across the fold is animatable.**
    ///
    /// The one that caught this: the sweep into the border is zero folded and
    /// its full depth open, so without `animatableData` the ears popped into
    /// existence on the first frame of an otherwise smooth movement.
    func testWhatDiffersAcrossTheFoldIsCarriedByTheAnimation() {
        let shut = model(false).notchShape, open = model(true).notchShape
        XCTAssertNotEqual(shut.filletDepth, open.filletDepth,
                          "nothing differs, so this test is measuring nothing")

        var morphed = shut
        morphed.animatableData = open.animatableData
        XCTAssertEqual(morphed.filletDepth, open.filletDepth,
                       "the sweep is not carried by the animation — it will pop")
        XCTAssertEqual(morphed.filletRadius, open.filletRadius,
                       "the sweep's width is not carried by the animation")
        XCTAssertEqual(morphed.cornerRadius, open.cornerRadius, accuracy: 0.001)
        XCTAssertEqual(morphed.bezelHidden, open.bezelHidden, accuracy: 0.001)
    }

    /// Halfway through, it is halfway — a real shape, not either end.
    func testHalfwayThroughTheFoldItIsHalfAShape() {
        let shut = model(false), open = model(true)
        var half = shut.notchShape
        let a = shut.notchShape.animatableData
        let b = open.notchShape.animatableData
        let corner: CGFloat = (a.first.first + b.first.first) / 2
        let width: CGFloat = (a.first.second + b.first.second) / 2
        let depthHalf: CGFloat = (a.second.first + b.second.first) / 2
        let band: CGFloat = (a.second.second + b.second.second) / 2
        let top = AnimatablePair<CGFloat, CGFloat>(corner, width)
        let bottom = AnimatablePair<CGFloat, CGFloat>(depthHalf, band)
        half.animatableData = AnimatablePair(top, bottom)
        let depth = try? XCTUnwrap(half.filletDepth)
        XCTAssertNotNil(depth)
        XCTAssertGreaterThan(depth ?? 0, 0, "half open, the sweep has not started")
        XCTAssertLessThan(depth ?? .infinity, open.splitFilletDepth ?? 0,
                          "half open, the sweep is already fully out")

        let size = CGSize(width: open.shapeLength, height: open.notchDepth)
        XCTAssertFalse(half.path(in: CGRect(origin: .zero, size: size)).isEmpty,
                       "the halfway shape does not draw")
    }

    /// A spring with some mass and a little overshoot, not a switch.
    func testTheFoldSpringHasMass() {
        XCTAssertEqual(NotchMotion.unfold, Animation.spring(response: 0.62,
                                                            dampingFraction: 0.72),
                       "the fold is no longer the heavy spring it was tuned to")
    }
}

/// The settings arc hugs the bar's corner. It is drawn inside the orb, which is
/// scaled to the bar — and the arc must not be.
@MainActor
final class ArcHugsTheCornerTests: XCTestCase {
    private func model(_ scale: CGFloat) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.sizeScale = scale
        m.isExpanded = true
        m.snapshots = (0..<4).map {
            ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        m.hardwareNotch = HardwareNotch(width: 220, height: 38)
        return m
    }

    /// **What the view draws, after its own scaling, is what the model meant.**
    ///
    /// The orb's view sits inside `.scaleEffect(sizeScale * orbScale)` and
    /// scales everything handed to it, so the values it is given are divided
    /// by `orbScale` first. Passed raw, the arc was shrunk a second time and
    /// drifted off the corner it is supposed to hug.
    func testTheArcSurvivesTheOrbsOwnScaling() {
        for scale: CGFloat in [0.8, 1.0, 1.25] {
            let m = model(scale)
            XCTAssertEqual(m.orbArcRadiusInOrbSpace * m.orbScale, m.orbArcRadius,
                           accuracy: 0.001, "at \(scale) the drawn arc is not the radius "
                           + "the model chose")
            XCTAssertEqual(m.orbArcOffsetInOrbSpace.width * m.orbScale,
                           m.orbArcOffset.width, accuracy: 0.001)
            XCTAssertEqual(m.orbArcOffsetInOrbSpace.height * m.orbScale,
                           m.orbArcOffset.height, accuracy: 0.001)
            XCTAssertEqual(m.moveArcOffsetInOrbSpace.width * m.orbScale,
                           m.moveArcOffset.width, accuracy: 0.001)
        }
    }

    /// And where it lands is one gap outside the corner, concentric with it.
    func testTheArcIsConcentricWithTheBarsCorner() {
        for scale: CGFloat in [0.8, 1.0, 1.25] {
            let m = model(scale)
            let centre = CGPoint(x: m.orbAlong + m.orbArcOffset.width,
                                 y: m.orbInset + m.orbArcOffset.height)
            XCTAssertEqual(centre.x, m.cornerCentreAlong, accuracy: 0.001,
                           "at \(scale) the arc is not centred on the corner")
            XCTAssertEqual(centre.y, m.drawnFoot - m.drawnCornerRadius, accuracy: 0.001,
                           "at \(scale) the arc is not centred on the corner")
            XCTAssertEqual(m.orbArcRadius - m.drawnCornerRadius,
                           NotchLayout.orbGap * m.orbScale, accuracy: 0.001,
                           "at \(scale) the arc does not trace the corner by one gap")
        }
    }
}

/// The cutout's depth, from whichever signal AppKit is willing to give.
final class HardwareNotchDepthTests: XCTestCase {
    /// The bug: the bar came out shallower than the hole it is drawn as.
    ///
    /// `safeAreaInsets.top` is the area the system asks apps to keep clear, so
    /// it collapses when the menu bar is hidden or auto-hides. The hole does
    /// not. The strips either side of the notch are its own height and keep
    /// reporting it, so they carry the answer when the inset gives up.
    func testAHiddenMenuBarDoesNotShrinkTheNotch() {
        XCTAssertEqual(HardwareNotch.height(safeAreaTop: 0, beside: [38, 38]), 38,
                       "a hidden menu bar made the notch shallower than the hole")
        XCTAssertEqual(HardwareNotch.height(safeAreaTop: 24, beside: [38, 38]), 38,
                       "the menu bar's own height was taken for the notch's")
    }

    /// And when the inset is the fuller answer, it wins.
    func testTheDeepestSignalIsTheOne() {
        XCTAssertEqual(HardwareNotch.height(safeAreaTop: 38, beside: [32, 32]), 38)
        XCTAssertEqual(HardwareNotch.height(safeAreaTop: 38, beside: []), 38)
        XCTAssertEqual(HardwareNotch.height(safeAreaTop: 0, beside: []), 0,
                       "a screen with nothing to report must still say nothing")
    }
}

/// The tooltip hangs off the notch's foot, and beside the hardware that foot
/// is the cutout's — not the stacked layout's, some 60pt lower.
@MainActor
final class TooltipMeetsTheBarTests: XCTestCase {
    private func model(_ scale: CGFloat) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.sizeScale = scale
        m.isExpanded = true
        m.snapshots = (0..<4).map {
            ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        m.hardwareNotch = HardwareNotch(width: 220, height: 38)
        return m
    }

    /// The bug: a stretch of wallpaper between the card's tail and the notch
    /// it points at, because the tail was measured from a depth the bar no
    /// longer has.
    func testTheTailStartsAtTheBarsFoot() {
        for scale: CGFloat in [1.0, 1.5] {
            let m = model(scale)
            XCTAssertEqual(m.notchDrawnDepth, m.splitDrawnDepth, accuracy: 0.01,
                           "at \(scale) the tooltip is measured from the wrong depth")
            XCTAssertEqual(m.tooltipInset - m.splitDrawnDepth, NotchLayout.tailGap,
                           accuracy: 0.01,
                           "at \(scale) the card sits \(m.tooltipInset - m.splitDrawnDepth)pt "
                           + "below the bar instead of \(NotchLayout.tailGap)")
        }
    }

    /// And it is nowhere near the stacked layout's depth, which is what it used
    /// to use — this is the size of the mistake.
    func testItIsNotTheStackedDepth() {
        let m = model(1.0)
        let stacked = (m.contentInset + NotchLayout.bodyDepth(for: .top)) * m.sizeScale
        XCTAssertGreaterThan(stacked - m.notchDrawnDepth, 20,
                             "the two depths agree, so this test proves nothing")
    }
}


/// The percentage under each ring, beside the hardware notch, is a choice.
@MainActor
final class NotchReadingsAreOptionalTests: XCTestCase {
    private func model(_ scale: CGFloat, on: Bool) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.sizeScale = scale
        m.isExpanded = true
        m.showsNotchReadings = on
        m.snapshots = (0..<4).map {
            ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        m.hardwareNotch = HardwareNotch(width: 220, height: 38)
        return m
    }

    /// Turned off, no edge draws it.
    func testNothingDrawsItWhenItIsOff() {
        XCTAssertFalse(model(1.0, on: false).splitShowsReading)
        XCTAssertFalse(model(1.5, on: false).splitShowsReading)
    }

    /// **What it costs.** A ring and its reading need more depth than the
    /// cutout has, so the reading is paid for out of the ring.
    func testTurningItOnBuysTheReadingWithRingSize() {
        let off = model(1.5, on: false), on = model(1.5, on: true)
        XCTAssertTrue(on.splitShowsReading, "there is depth for it at 150% and it is off")
        XCTAssertLessThan(on.splitDrawnRing, off.splitDrawnRing,
                          "the reading appeared without the ring giving anything up, "
                          + "which means it is being drawn somewhere it does not fit")
        XCTAssertEqual(on.splitDrawnCell + 2 * on.splitDrawnMargin, on.splitDrawnDepth,
                       accuracy: 0.01, "the cell is not centred in the bar's depth")
    }

    /// **And there is no floor under it.** Asked for, it is drawn, however
    /// small the strip leaves it — it briefly refused below about 130%, where
    /// the number comes out around 7pt, and a setting that silently does
    /// nothing is worse than a small number.
    func testItIsDrawnEvenWhereTheStripLeavesLittleRoom() {
        for scale: CGFloat in [0.75, 1.0, 1.5] {
            XCTAssertTrue(model(scale, on: true).splitShowsReading,
                          "asked for at \(scale) and not drawn")
        }
    }

    /// The same switch on every edge, not just the one where it costs
    /// something — a reading that vanished on moving the notch would read as
    /// a bug rather than a setting.
    func testItGovernsEveryPlacement() {
        let plain = NotchViewModel()
        plain.edge = .right
        plain.showsNotchReadings = false
        XCTAssertFalse(plain.showsCellReading)
        plain.showsNotchReadings = true
        XCTAssertTrue(plain.showsCellReading)
        XCTAssertFalse(model(1.0, on: false).showsCellReading)
        XCTAssertTrue(model(1.0, on: true).showsCellReading)
    }
}

/// Folded, a notch that is not beside the hardware is the small pill it has
/// always been — and the flare on it is a quarter circle, not an ellipse.
@MainActor
final class FoldedPillKeepsItsShapeTests: XCTestCase {
    private func folded(_ edge: NotchEdge) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = edge
        m.isExpanded = false
        m.snapshots = (0..<3).map {
            ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        return m
    }

    /// The bug: separating the flare's length from its depth dropped the clamp
    /// that kept the length inside the shape. On a pill 8pt deep the flare is
    /// bounded to about 4pt across — and was stretching 33pt along it.
    func testTheFlareCannotOutrunThePillItIsDrawnOn() {
        for edge in [NotchEdge.right, .left, .bottom] {
            let m = folded(edge)
            let size = m.notchSize
            let place = NotchPlacement(edge: edge, panelSize: size)
            let path = m.notchShape.path(in: CGRect(origin: .zero, size: size))

            // The pill's own extent along its edge, measured off the path at
            // the row furthest from the bezel.
            let hits = stride(from: CGFloat(0), to: NotchLayout.pillHeight, by: 0.5)
                .filter { path.contains(place.point(along: $0, across: NotchLayout.pillWidth - 1)) }
            guard let first = hits.first, let last = hits.last else {
                return XCTFail("\(edge): nothing drawn at the pill's foot")
            }
            let lost = NotchLayout.pillHeight - (last - first)
            XCTAssertLessThan(lost, NotchLayout.pillWidth * 2 + 2,
                              "\(edge): the flare takes \(lost)pt off a "
                              + "\(NotchLayout.pillHeight)pt pill — it cannot cut deeper "
                              + "than the pill is thick")
        }
    }

    /// And it is still the pill: full length at the bezel.
    func testItIsStillThePill() {
        for edge in [NotchEdge.right, .left, .bottom] {
            let m = folded(edge)
            XCTAssertEqual(m.notchLength, NotchLayout.pillHeight, accuracy: 0.001, "\(edge)")
            XCTAssertEqual(m.notchDepth, NotchLayout.pillWidth, accuracy: 0.001, "\(edge)")
        }
    }
}

/// Folded, the shape sits over the cutout — not beside it.
@MainActor
final class FoldedShapeSitsOnTheCutoutTests: XCTestCase {
    private func model(cells: Int) -> NotchViewModel {
        let m = NotchViewModel()
        m.edge = .top
        m.snapshots = (0..<cells).map {
            ProviderSnapshot(id: "p\($0)", displayName: "p", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        m.hardwareNotch = HardwareNotch(width: 220, height: 38)
        return m
    }

    /// The bug: `splitShift` lands the shape's *gap* on the hardware, and with
    /// an odd ring count that is some 21pt off centre. Folded there is no gap
    /// — the shape is the cutout — so the shift left a band of black beside a
    /// notch that should have been invisible, and a sideways slide as it
    /// opened.
    func testItIsNotShiftedWhileFolded() {
        for cells in 1...5 {
            let m = model(cells: cells)
            m.isExpanded = false
            XCTAssertEqual(m.drawnSplitShift, 0, accuracy: 0.001,
                           "\(cells) rings: the folded cutout is drawn "
                           + "\(m.drawnSplitShift)pt off the hole")
        }
    }

    /// And open it is shifted again, or the gap misses the hole.
    func testItIsShiftedOnceThereIsAGap() {
        for cells in [1, 3, 5] {
            let m = model(cells: cells)
            m.isExpanded = true
            XCTAssertEqual(m.drawnSplitShift, m.splitShift, accuracy: 0.001,
                           "\(cells) rings: the gap will not land on the hole")
            XCTAssertNotEqual(m.splitShift, 0, accuracy: 0.001,
                              "\(cells) rings should split unevenly")
        }
    }

    /// The window still holds the open notch either way.
    func testTheSizingKeepsTheOpenShift() {
        let m = model(cells: 3)
        m.screenSize = CGSize(width: 1800, height: 1169)
        m.isExpanded = false
        let shut = m.panelSize(cellCount: 3).width
        m.isExpanded = true
        XCTAssertEqual(shut, m.panelSize(cellCount: 3).width, accuracy: 0.01)
    }
}
