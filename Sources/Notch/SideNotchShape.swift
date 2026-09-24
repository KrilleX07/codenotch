import SwiftUI

/// The notch body: a pill welded to one edge of the screen, with *inverse*
/// rounded corners at each end that flare back out to the edge so it reads as
/// part of the bezel rather than a floating panel.
///
/// The path is only ever written once, for the right edge, and then transformed
/// onto whichever edge it is actually on. Writing four variants would mean four
/// copies of the corner-versus-flare clamping below, which is the one piece of
/// this that took real work to get right — and three of the copies would never
/// be the one under the cursor when it broke.
///
/// In canonical form `rect` is the whole shape including the flares; the
/// straight body runs from `rect.minY + curlRadius` to `rect.maxY - curlRadius`,
/// and `rect.maxX` is the screen edge.
struct SideNotchShape: Shape {
    var edge: NotchEdge = .right
    /// The display's own notch, when this one is drawn as it.
    ///
    /// Set for a top edge on a Mac that has one, and it changes two things.
    /// The flares go: they are what make this shape read as *growing out of* an
    /// edge, and the hardware notch does not taper — it is a straight-sided
    /// black rectangle hanging from the top with two rounded bottom corners.
    /// And the corner is capped at half the hardware's own height, so it is the
    /// same size at rest as it is open: left to the frame it is clamped to half
    /// the *current* depth, which makes the resting shape very nearly a pill
    /// and turns opening it into a rounded tab morphing into a bar rather than
    /// the notch stretching.
    var joining: HardwareNotch?
    var curlRadius: CGFloat = NotchLayout.curlRadius
    var cornerRadius: CGFloat = NotchLayout.cornerRadius
    /// The inverse curve where the shape meets the bezel, when the caller wants
    /// one of its own. Nil takes the fixed `bezelFillet` a joined shape used to
    /// get unconditionally — right when the bar *was* the hardware, too abrupt
    /// once it extends past it as ears that have to flow into the screen edge.
    var filletRadius: CGFloat?

    /// How much *depth* that sweep uses, when it is not the same as how far it
    /// runs along the bar. Nil keeps them equal, which is a circular arc.
    ///
    /// They are separate because the two are bounded by different things. The
    /// depth is all the ear has — 38pt beside the hardware, shared with the
    /// corner at its foot — while the length is not scarce at all. Holding the
    /// depth and stretching the length flattens the sweep, which is the only
    /// way left to make it gentler once it already reaches the corner.
    var filletDepth: CGFloat?

    /// How much of the sweep is spent ramping its bend in and out — see
    /// `fluidTurn`. 0 is a plain arc; 0.5 never holds a constant bend at all.
    var filletRamp: CGFloat = 0.5

    /// The band of depth at the bezel that nobody can see.
    ///
    /// The shape is pushed this far *past* the top of the screen so no
    /// wallpaper hairline shows along the bezel. Anything curved up there is
    /// spent where it cannot be seen, and what reaches the screen is a curve
    /// already part way through its turn, cut off by the border — the tip ends
    /// up over the edge rather than on it. So the band is kept straight and
    /// the sweep starts at the first row that is actually on screen.
    var bezelHidden: CGFloat = 0
    /// The most the corner may be, when the caller knows better than half the
    /// hardware's height. Beside the hole the bar is the hardware's depth, and
    /// half of that is a pill end rather than a notch corner.
    var cornerCapOverride: CGFloat?

    /// **What morphs when the notch folds.**
    ///
    /// Without this the shape is rebuilt from scratch on the frame that the
    /// fold begins: the rect it is drawn into animates, but the numbers it is
    /// drawn *from* do not. Beside the hardware the sweep into the border goes
    /// from nothing to its full depth the instant `isExpanded` flips, so the
    /// ears arrive with a pop in the middle of an otherwise smooth movement —
    /// which is most of what "it does not feel fluid" is.
    ///
    /// Each of these is a length in the shape's own space, so interpolating
    /// them is exactly the morph you want: the corner opens out, the sweep
    /// grows from the border, and the hidden band keeps pace with both.
    ///
    /// Whether a fillet is `nil` never changes while a shape is on screen — it
    /// follows the placement, not the state — so the optionals are carried
    /// through untouched rather than given a sentinel to interpolate against.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(cornerRadius, filletRadius ?? 0),
                           AnimatablePair(filletDepth ?? 0, bezelHidden))
        }
        set {
            cornerRadius = newValue.first.first
            if filletRadius != nil { filletRadius = newValue.first.second }
            if filletDepth != nil { filletDepth = newValue.second.first }
            bezelHidden = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Canonical space: depth across the shape, length along it. For a side
        // edge that is already width x height; for a horizontal one it is the
        // rect turned on its side. The bezel is at `maxX`.
        let depth = edge.isVertical ? rect.width : rect.height
        let length = edge.isVertical ? rect.height : rect.width
        let canonical = canonicalPath(
            in: CGRect(x: 0, y: 0, width: depth, height: length),
            flare: filletRadius ?? (joining == nil ? curlRadius : NotchLayout.bezelFillet),
            flareDepth: filletDepth,
            // Half the hardware's height is the most the resting shape can
            // carry; holding it there keeps every frame of the expansion the
            // same shape, only bigger.
            cornerCap: cornerCapOverride ?? joining.map { $0.height / 2 } ?? .greatestFiniteMagnitude
        )

        return canonical
            .applying(Self.transform(for: edge, depth: depth))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Canonical (`u`, `v`) — `u` across from the far side, `v` along — onto the
    /// rect's own coordinates, with the bezel landing on the right edge.
    ///
    /// Derived rather than eyeballed: in stack space the bezel is always
    /// `across == 0`, so `across = depth - u`, and each edge then places
    /// `(along, across)` the same way `NotchPlacement` does.
    static func transform(for edge: NotchEdge, depth: CGFloat) -> CGAffineTransform {
        switch edge {
        case .right:
            return .identity
        case .left:
            // Mirrored: the flares point the other way.
            return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: depth, ty: 0)
        case .top:
            // Quarter turn, bezel to the top.
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: depth)
        case .bottom:
            // Quarter turn the other way, bezel to the bottom.
            return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        }
    }

    /// The handle reach that makes a cubic Bézier trace a circle exactly.
    ///
    /// Every corner here is a circular arc, and two attempts at making them
    /// something cleverer both came back as "stiff". The reason is curvature
    /// at the *joins*, not the shape in the middle. Reach further than this
    /// and the curve holds flat against each straight and turns late — the
    /// squircle. Reach less and it turns early. Either way a single cubic that
    /// matches a target outline ends up with the wrong curvature where it
    /// meets the straight: at reach 0.37 it is three times a circle's, and the
    /// eye reads that jump as a kink however good the outline is.
    ///
    /// A circle has one curvature throughout, so the only jump is the
    /// unavoidable one from the straight line — and that is what Apple's notch
    /// does. Fitted over the whole sweep, its corner is an arc to within a
    /// pixel; the fit prefers it over every ramped or squircled alternative.
    static let circleReach: CGFloat = 0.5523

    /// **A quarter turn whose bend ramps in from nothing at both ends.**
    ///
    /// Where the sweep meets the screen's border, a Bézier arrives at the right
    /// *angle* but with its whole bend already there — curvature goes from none
    /// along the border to all of it in one step, and the eye reads that step
    /// as a stiff join however the outline is shaped. No single cubic can avoid
    /// it: holding curvature at zero at both ends of a quarter turn takes all
    /// four control points, and they are spoken for by the tangents.
    ///
    /// So this is not one: the curve is integrated from its curvature directly,
    /// which rises from zero, holds, and falls back to zero. `ramp` is the
    /// share of the turn spent rising and falling at each end — 0 is a circular
    /// arc, 0.5 ramps the whole way with no constant-curvature middle at all.
    /// The result is walked out as a polyline, fine enough that the facets are
    /// far below a point at any size the notch is drawn.
    private func fluidTurn(_ path: inout Path, to: CGPoint,
                           leaving: CGVector, arriving: CGVector, ramp: CGFloat) {
        guard let from = path.currentPoint else { return }
        let alongReach = (to.x - from.x) * leaving.dx + (to.y - from.y) * leaving.dy
        let acrossReach = (to.x - from.x) * arriving.dx + (to.y - from.y) * arriving.dy
        guard alongReach != 0, acrossReach != 0 else {
            path.addLine(to: to)
            return
        }
        let p = min(max(ramp, 0), 0.5)
        // Curvature times length, set so the turn comes to exactly a quarter.
        let bend = (CGFloat.pi / 2) / (1 - p)
        let steps = 96
        var heading: CGFloat = 0, u: CGFloat = 0, v: CGFloat = 0
        var walk: [(CGFloat, CGFloat)] = [(0, 0)]
        for i in 0..<steps {
            let s = (CGFloat(i) + 0.5) / CGFloat(steps)
            let share = p <= 0 ? 1 : (s < p ? s / p : (s > 1 - p ? (1 - s) / p : 1))
            heading += bend * share / CGFloat(steps)
            u += cos(heading) / CGFloat(steps)
            v += sin(heading) / CGFloat(steps)
            walk.append((u, v))
        }
        // The walk is symmetric, so one scale per axis lands it on `to`.
        let (endU, endV) = walk[walk.count - 1]
        let alongScale = alongReach / endU, acrossScale = acrossReach / endV
        for (wu, wv) in walk.dropFirst() {
            path.addLine(to: CGPoint(
                x: from.x + leaving.dx * wu * alongScale + arriving.dx * wv * acrossScale,
                y: from.y + leaving.dy * wu * alongScale + arriving.dy * wv * acrossScale))
        }
    }

    /// A quarter turn from the current point to `to`, leaving along `leaving`
    /// and arriving along `arriving`.
    ///
    /// Each handle is `circleReach` of the distance the turn covers *on its own
    /// axis*, taken from the endpoints rather than from one radius. When the
    /// two distances match that is a circular arc exactly; when they differ it
    /// is the corresponding quarter ellipse, which is how the sweep into the
    /// screen's edge can run wide along the bar without getting any deeper.
    private func turn(_ path: inout Path, to: CGPoint,
                      leaving: CGVector, arriving: CGVector, radius: CGFloat,
                      leavingReach: CGFloat = SideNotchShape.circleReach,
                      arrivingReach: CGFloat = SideNotchShape.circleReach) {
        guard radius > 0, let from = path.currentPoint else {
            path.addLine(to: to)
            return
        }
        let delta = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let out = abs(delta.dx * leaving.dx + delta.dy * leaving.dy)
        let into = abs(delta.dx * arriving.dx + delta.dy * arriving.dy)
        guard out > 0, into > 0 else {
            path.addLine(to: to)
            return
        }
        path.addCurve(
            to: to,
            control1: CGPoint(x: from.x + leaving.dx * out * leavingReach,
                              y: from.y + leaving.dy * out * leavingReach),
            control2: CGPoint(x: to.x - arriving.dx * into * arrivingReach,
                              y: to.y - arriving.dy * into * arrivingReach)
        )
    }


    private func canonicalPath(in rect: CGRect, flare: CGFloat,
                               flareDepth: CGFloat? = nil,
                               cornerCap: CGFloat = .greatestFiniteMagnitude) -> Path {
        // Order matters. Clamping the corner by `width - curl` — the obvious
        // reading — collapses it to zero as soon as the flare is as wide as the
        // body, which is exactly what happens when the notch folds to its pill:
        // a 10pt-wide shape came out with square corners. The corner is claimed
        // first, out of half the width, and the flare takes what is left.
        let wanted = max(0, min(cornerRadius, cornerCap, rect.width / 2))
        // Along the bar, and across it.
        //
        // The two are independent only when the caller has asked for them to
        // be — that is what an elliptical sweep is. Left to itself the flare is
        // a quarter circle, and then the across clamp binds the along as well:
        // the depth is what is scarce, and a circle cannot be 33pt long and
        // 4pt deep. Dropping that term stretched the folded pill's flare over
        // half its length and left it a shape nobody recognised.
        let curlDepth = max(0, min(flareDepth ?? flare, rect.width - wanted))
        let curl = flareDepth == nil
            ? curlDepth
            : max(0, min(flare, rect.height / 2))
        let corner = max(0, min(wanted, (rect.height - 2 * curl) / 2))
        let bodyTop = rect.minY + curl
        let bodyBottom = rect.maxY - curl

        // Never more than the band itself, and never so much that it eats the
        // sweep it is making room for.
        let hidden = max(0, min(bezelHidden, rect.width - wanted - curlDepth))

        var path = Path()
        // Screen edge, above the body.
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        if hidden > 0 { path.addLine(to: CGPoint(x: rect.maxX - hidden, y: rect.minY)) }
        // Flare inward and down onto the top edge. Absent when flush: the
        // shape meets the bezel square, as the hardware notch does.
        if curl > 0 {
            fluidTurn(&path, to: CGPoint(x: rect.maxX - hidden - curlDepth, y: bodyTop),
                      leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: -1, dy: 0),
                      ramp: filletRamp)
        }
        path.addLine(to: CGPoint(x: rect.minX + corner, y: bodyTop))
        turn(&path, to: CGPoint(x: rect.minX, y: bodyTop + corner),
             leaving: CGVector(dx: -1, dy: 0), arriving: CGVector(dx: 0, dy: 1),
             radius: corner)
        path.addLine(to: CGPoint(x: rect.minX, y: bodyBottom - corner))
        turn(&path, to: CGPoint(x: rect.minX + corner, y: bodyBottom),
             leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: 1, dy: 0),
             radius: corner)
        path.addLine(to: CGPoint(x: rect.maxX - hidden - curlDepth, y: bodyBottom))
        // Flare back out to the screen edge.
        if curl > 0 {
            fluidTurn(&path, to: CGPoint(x: rect.maxX - hidden, y: rect.maxY),
                      leaving: CGVector(dx: 1, dy: 0), arriving: CGVector(dx: 0, dy: 1),
                      ramp: filletRamp)
        }
        // Back out across the hidden band, whether or not there was a sweep —
        // left inside the branch above it, the flush shape came out a band
        // short on this side and no longer matched itself end to end.
        if hidden > 0 { path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) }
        path.closeSubpath()
        return path
    }
}
