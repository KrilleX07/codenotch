import AppKit

/// The display's *own* notch — the camera housing on a MacBook, not ours.
///
/// Worth naming, because it is the one piece of the screen that is not a screen:
/// pixels drawn there are behind a hole, not merely covered.
struct HardwareNotch: Equatable {
    let width: CGFloat
    let height: CGFloat

    /// **How deep the cutout is**, from every signal AppKit offers rather than
    /// the one that seemed obvious.
    ///
    /// `safeAreaInsets.top` was it, and it is not dependable: it describes the
    /// area the system is asking apps to keep clear, so it collapses when the
    /// menu bar is hidden or set to auto-hide. The hole in the display does not
    /// move when that happens, so the bar came out shallower than the cutout it
    /// is supposed to be — a step along the bottom of the notch.
    ///
    /// The strips either side of the notch are the notch's own height and keep
    /// reporting it either way, so the deepest of the three is the cutout.
    static func height(safeAreaTop: CGFloat, beside strips: [CGFloat]) -> CGFloat {
        max(safeAreaTop, strips.max() ?? 0)
    }
}

/// Everything the geometry maths needs from a screen, so it can be faked in tests.
protocol ScreenDescribing {
    var frameValue: CGRect { get }
    var visibleFrameValue: CGRect { get }
    var hardwareNotch: HardwareNotch? { get }
    var displayIdentifier: String? { get }
}

extension ScreenDescribing {
    /// Most displays have none, and most tests do not care.
    var hardwareNotch: HardwareNotch? { nil }
    var displayIdentifier: String? { nil }
}

extension NSScreen: ScreenDescribing {
    var frameValue: CGRect { frame }
    var visibleFrameValue: CGRect { visibleFrame }

    /// Unlike `CGDirectDisplayID`, this UUID survives display reconfiguration
    /// and restarts, so a saved choice still names the same physical monitor.
    var displayIdentifier: String? {
        let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[screenNumber] as? NSNumber,
              let unmanaged = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)
        else { return nil }
        let uuid = unmanaged.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Measured from the two menu-bar strips *either side* of the notch, which
    /// is the only thing AppKit describes directly. A display without a notch
    /// reports no auxiliary areas.
    var hardwareNotch: HardwareNotch? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            return nil
        }
        let width = frame.width - left.width - right.width
        let height = HardwareNotch.height(safeAreaTop: safeAreaInsets.top,
                                          beside: [left.height, right.height])
        guard width > 0, height > 0 else { return nil }
        return HardwareNotch(width: width, height: height)
    }
}

enum NotchGeometry {
    /// Bezel left between the display's cutout and a notch placed beside it.
    /// Enough to read as two objects rather than one smudge, little enough to
    /// read as *beside* rather than merely elsewhere on the edge.
    static let cutoutGap: CGFloat = 10

    /// Anchor to the physical display edge, even when the Dock or menu bar
    /// reserves part of the desktop. Showing or hiding either must not move
    /// a position the user chose.
    ///
    /// The rect is rounded out to whole points on purpose. AppKit rounds window
    /// frames anyway, and if it does the rounding the panel ends up a fraction
    /// larger than asked for — which leaves the content, laid out at its exact
    /// size, stopping short of the screen edge. A hairline of wallpaper along
    /// that edge is all it takes for the notch to read as floating rather than
    /// welded to the bezel.
    static func panelFrame(
        for screen: ScreenDescribing,
        panelSize: CGSize,
        edge: NotchEdge = .right,
        // A user-chosen nudge along the edge, from `NotchViewModel.alongOffset`
        // — zero is the centred default this file always drew before the nudge
        // existed. Vertical edges read it as AppKit's y running *down* the
        // screen (dragging the pill down increases it); horizontal edges read
        // it as x running right, which needs no such flip.
        alongOffset: CGFloat = 0,
        // The padding `panelSize` carries on *each* end beyond the visible
        // pill, reserved for a hover card that is not there right now —
        // `NotchViewModel.slack`. Clamping the offset by the padded size
        // would have left the pill only a sliver of room to move in on most
        // screens, since that padding is sized for the tallest possible card
        // and can be most of the panel. Clamping by the pill's own extent
        // instead — `panelSize` shrunk by this on each end — lets it travel
        // almost the full edge; the padding is free to run past the bezel,
        // since nothing is drawn there until a card actually opens.
        slack: CGFloat = 0,
        // The handles can hang past either end of the body. Those parts of
        // the padding must stay on screen even when the hover card may not.
        trailingExtent: CGFloat = 0,
        leadingExtent: CGFloat = 0
    ) -> CGRect {
        let full = screen.frameValue
        let width = panelSize.width.rounded(.up)
        let height = panelSize.height.rounded(.up)

        let origin: CGPoint
        switch edge {
        case .right:
            let y = clamp(full.midY - height / 2 - alongOffset,
                          min: full.minY - slack + trailingExtent,
                          max: full.maxY - height + slack - leadingExtent)
            origin = CGPoint(x: full.maxX - width, y: y)
        case .left:
            let y = clamp(full.midY - height / 2 - alongOffset,
                          min: full.minY - slack + trailingExtent,
                          max: full.maxY - height + slack - leadingExtent)
            origin = CGPoint(x: full.minX, y: y)
        case .top:
            // **Beside the display's own cutout, where it has one.**
            //
            // The notch is drawn the same way on all four edges — see
            // `NotchViewModel`, which knows nothing about the hardware. The
            // one thing the cutout decides is where the top edge's notch
            // *sits*, and that is settled here.
            //
            // Not centred, which buries it in the hole: that band is not a dim
            // part of the screen, it is absent, and anything drawn there is not
            // on screen at all. Not below it either — dropping the panel clear
            // of the hole leaves the notch hanging in the wallpaper under the
            // cutout, attached to nothing. So it sits on the bezel immediately
            // past the hole's edge, which is the only placement that reads as
            // belonging to the machine.
            //
            // Measured on the *visible* notch, not the panel: the panel
            // carries `slack` at each end for a hover card that is usually not
            // there, so the panel's centre has to land that much further right
            // for the notch inside it to clear the hole.
            var besideCutout: CGFloat = 0
            if let cutout = screen.hardwareNotch {
                let half: CGFloat = cutout.width / 2
                besideCutout = half + cutoutGap + width / 2 - slack
            }
            let centred: CGFloat = full.midX - width / 2 + alongOffset
            let x = clamp(centred + besideCutout,
                          min: full.minX - slack + leadingExtent,
                          max: full.maxX - width + slack - trailingExtent)
            origin = CGPoint(x: x, y: full.maxY - height)
        case .bottom:
            let x = clamp(full.midX - width / 2 + alongOffset,
                          min: full.minX - slack + leadingExtent,
                          max: full.maxX - width + slack - trailingExtent)
            origin = CGPoint(x: x, y: full.minY)
        }

        return CGRect(
            x: origin.x.rounded(),
            y: origin.y.rounded(),
            width: width,
            height: height
        )
    }

    static func preferredScreen(
        from screens: [NSScreen],
        preference: DisplayPreference = .followActiveWindow
    ) -> NSScreen? {
        preferredScreen(from: screens, preference: preference, activeScreen: NSScreen.main)
    }

    /// Kept generic so display selection can be proved without relying on the
    /// monitors attached to the machine running the tests.
    static func preferredScreen<Screen: ScreenDescribing>(
        from screens: [Screen],
        preference: DisplayPreference,
        activeScreen: Screen?
    ) -> Screen? {
        if case .display(let id) = preference,
           let selected = screens.first(where: { $0.displayIdentifier == id }) {
            return selected
        }
        return activeScreen ?? screens.first
    }

    /// Keeps a dragged offset from pushing the visible pill off the screen it
    /// is on. A plain `ClosedRange` clamp would trap if the pill were ever
    /// taller or wider than the screen, which a very small display could
    /// make true.
    private static func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        guard lo <= hi else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }
}
