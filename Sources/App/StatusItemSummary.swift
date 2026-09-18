import AppKit

/// What the menu bar item says in place of its icon: for each provider with a
/// five-hour limit, its mark, how much of that window is spent, and how long
/// until it resets — "72% · 2h 18m".
///
/// Built from the same snapshots as the menu under it, never from a reading of
/// its own. Pure, so everything the bar can say, down to "—", can be tested
/// without a status item or a clock.
struct StatusItemSummary: Equatable {
    struct Entry: Equatable {
        let id: String
        let glyph: ProviderGlyph
        /// The profile's slug, only when another entry wears the same mark:
        /// two Claude logins would otherwise be two identical icons.
        let label: String?
        /// "72%", or `unknown` when there is no current five-hour reading.
        let percent: String
        /// "2h 18m", or `unknown` when the reset is unknown or already past.
        let countdown: String
        /// A remembered reading rather than a fresh one, dimmed the way the
        /// notch dims its ring.
        let isStale: Bool
        /// What the tooltip and VoiceOver say about this entry, in full.
        let detail: String

        static let unknown = "—"

        /// Nothing to show at all, so it is drawn as the mark and one dash.
        var isBlank: Bool { percent == Self.unknown && countdown == Self.unknown }
    }

    let entries: [Entry]
    /// When the first countdown on show next reads differently. Nil when
    /// nothing is counting down, so nothing needs to wake up for it.
    let nextChange: Date?

    /// Two readings sit side by side comfortably. Past that each keeps its mark
    /// and percentage, and the countdowns stay in the tooltip and the menu.
    static let fullEntryLimit = 2
    /// Past this many the rest are in the menu only. macOS hides a status item
    /// that does not fit rather than squeezing it, and with the app out of the
    /// Dock this item is the only way into it.
    static let entryLimit = 4

    var isCompact: Bool { entries.count > Self.fullEntryLimit }

    /// Every provider that meters a five-hour window, in the order the notch
    /// shows them. Claude and Codex are summarised even before they have a
    /// reading: their headline limit *is* that window, so a missing figure is
    /// worth a dash rather than a silent gap. Anyone else joins once they
    /// report one.
    @MainActor
    static func make(from snapshots: [ProviderSnapshot], now: Date) -> StatusItemSummary {
        let summarised = snapshots.filter { snapshot in
            snapshot.kind == .usage
                && (snapshot.fiveHourWindow != nil || isFiveHourFamily(snapshot.id))
        }.prefix(entryLimit)
        var marks: [ProviderGlyph: Int] = [:]
        for snapshot in summarised { marks[snapshot.glyph, default: 0] += 1 }
        let entries = summarised.map { snapshot in
            entry(for: snapshot, sharesMark: marks[snapshot.glyph, default: 0] > 1, now: now)
        }
        let nextChange = summarised
            .compactMap { $0.fiveHourWindow?.resetsAt }
            .compactMap { ResetCopy.nextCountdownChange(to: $0, now: now) }
            .min()
        return StatusItemSummary(entries: entries, nextChange: nextChange)
    }

    static func isFiveHourFamily(_ providerID: String) -> Bool {
        ClaudeProfile.isClaude(providerID: providerID) || CodexProfile.isCodex(providerID: providerID)
    }

    @MainActor
    private static func entry(for snapshot: ProviderSnapshot, sharesMark: Bool,
                              now: Date) -> Entry {
        let window = snapshot.fiveHourWindow
        // Past its reset a reading describes a window that is over. The store
        // re-reads on its first tick after a reset; until that lands the honest
        // figure is none, not the old one.
        let isOver = window?.resetsAt.map { $0 <= now } ?? false
        var percent = Entry.unknown
        if !isOver, let fraction = window?.usedFraction, fraction.isFinite {
            percent = Percent.whole(for: fraction) + "%"
        }
        let countdown = window?.resetsAt.flatMap { ResetCopy.countdown(to: $0, now: now) }
        let label = sharesMark
            ? ClaudeProfile.slug(fromProviderID: snapshot.id) ?? CodexProfile.slug(fromProviderID: snapshot.id)
            : nil
        return Entry(
            id: snapshot.id,
            glyph: snapshot.glyph,
            label: label,
            percent: percent,
            countdown: countdown ?? Entry.unknown,
            isStale: snapshot.status.isStale && percent != Entry.unknown,
            detail: detail(for: snapshot, window: window, isOver: isOver,
                           countdown: countdown, now: now)
        )
    }

    /// The bar's figures with the words it has no room for: whose they are,
    /// which window, and what is left. The countdown is the bar's own, so the
    /// two never disagree by the minute that rounding would put between them.
    @MainActor
    private static func detail(for snapshot: ProviderSnapshot, window: LimitWindow?,
                               isOver: Bool, countdown: String?, now: Date) -> String {
        let reading: String
        if let window {
            let figures = isOver
                ? [L10n.t("Resetting…")]
                : [window.summary] + [countdown].compactMap { $0 }
            reading = "\(window.label): \(figures.joined(separator: " · "))"
        } else if let headline = snapshot.headline {
            // What the account does meter, so a dash in the bar is explained
            // rather than merely shown.
            reading = StatusItemController.windowLine(for: headline, now: now, format: .remaining)
        } else {
            reading = snapshot.statusMessage ?? L10n.t("No reading")
        }
        var line = "\(snapshot.displayName) — \(reading)"
        if snapshot.hasReading, let since = snapshot.status.staleSince, since != .distantPast {
            line += " · \(ElapsedCopy.ago(since: since, now: now))"
        }
        return line
    }
}

/// The summary as the menu bar draws it: one template image, so AppKit tints it
/// for whatever bar it is on — dark on light, light on dark, right against a
/// wallpaper-tinted bar — exactly as it does the icon it stands in for.
///
/// Measured here and drawn by the image's handler whenever AppKit wants pixels,
/// so it is sharp at whatever scale the display has.
struct StatusItemArtwork {
    let summary: StatusItemSummary
    let font: NSFont
    let height: CGFloat

    /// The menu bar's own type size, with figures of one width: "72%" and
    /// "18%" take the same room, so nothing jitters as the numbers move.
    init(summary: StatusItemSummary,
         font: NSFont = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
                                                   weight: .regular),
         height: CGFloat = NSStatusBar.system.thickness) {
        self.summary = summary
        self.font = font
        self.height = height
    }

    private enum Mark {
        case glyph(ProviderGlyph, NSRect)
        case text(String, NSPoint)
    }

    private var separator: String { " · " }
    private var glyphSize: CGFloat { (font.pointSize * 1.1).rounded() }
    private var glyphGap: CGFloat { (font.pointSize * 0.3).rounded() }
    private var entryGap: CGFloat { (font.pointSize * 0.8).rounded() }

    /// The widest either figure gets in the ordinary run of a window, measured
    /// in the current language. Each is given at least this much room, so the
    /// item keeps one width from the start of a window to its reset — the
    /// items to its left would otherwise shuffle every time "10%" became "9%"
    /// or "1h 00m" became "59m".
    private var percentRoom: CGFloat { width("00%") }
    private var countdownRoom: CGFloat {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        return width(ResetCopy.countdown(to: now.addingTimeInterval(5 * 3600 - 30), now: now) ?? "")
    }

    var size: NSSize { NSSize(width: layout().width, height: height) }

    func image() -> NSImage {
        let (width, marks) = layout()
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (mark, alpha) in marks { draw(mark, alpha: alpha) }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func layout() -> (width: CGFloat, marks: [(Mark, CGFloat)]) {
        // Figures centred on the bar by their cap height, which is what the eye
        // measures digits by; the marks are centred on the same line.
        let baseline = ((height - font.capHeight) / 2 * 2).rounded() / 2
        let middle = baseline + font.capHeight / 2
        var marks: [(Mark, CGFloat)] = []
        var x: CGFloat = 0
        func text(_ string: String, alpha: CGFloat) {
            marks.append((.text(string, NSPoint(x: x, y: baseline)), alpha))
            x += width(string)
        }
        for (index, entry) in summary.entries.enumerated() {
            if index > 0 { x += entryGap }
            let alpha: CGFloat = entry.isStale ? 0.5 : 1
            let box = NSRect(x: x, y: middle - glyphSize / 2, width: glyphSize, height: glyphSize)
            marks.append((.glyph(entry.glyph, box), alpha))
            x += glyphSize + glyphGap
            if let label = entry.label {
                text(label, alpha: alpha)
                x += glyphGap
            }
            if entry.isBlank {
                text(StatusItemSummary.Entry.unknown, alpha: alpha)
                continue
            }
            // Right-aligned, so the "%" stays put and the figure grows leftward.
            let percentWidth = width(entry.percent)
            x += max(0, percentRoom - percentWidth)
            text(entry.percent, alpha: alpha)
            guard !summary.isCompact else { continue }
            text(separator, alpha: alpha)
            let start = x
            text(entry.countdown, alpha: alpha)
            x = max(x, start + countdownRoom)
        }
        return (x.rounded(.up), marks)
    }

    private func width(_ string: String) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private func draw(_ mark: Mark, alpha: CGFloat) {
        // Black at some opacity: a template image is read only for its alpha,
        // and AppKit supplies the colour.
        let ink = NSColor.black.withAlphaComponent(alpha)
        switch mark {
        case .text(let string, let origin):
            // Without `.usesLineFragmentOrigin` the rect's origin is the baseline.
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: ink])
                .draw(with: NSRect(origin: origin, size: .zero), options: [], context: nil)
        case .glyph(let glyph, let box):
            let inset = box.width * (1 - glyph.opticalScale) / 2
            let rect = box.insetBy(dx: inset, dy: inset)
            // The same preference as the notch: a bundled asset over the trace,
            // fitted rather than stretched, since not every mark is square.
            if let asset = NSImage(named: glyph.assetName), asset.size.width > 0, asset.size.height > 0 {
                let scale = min(rect.width / asset.size.width, rect.height / asset.size.height)
                let fitted = NSSize(width: asset.size.width * scale, height: asset.size.height * scale)
                asset.draw(in: NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                                      width: fitted.width, height: fitted.height),
                           from: .zero, operation: .sourceOver, fraction: alpha)
                return
            }
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            // Outlines are traced top-down in a unit box; the image is not flipped.
            func point(_ p: CGPoint) -> NSPoint {
                NSPoint(x: rect.minX + p.x * rect.width, y: rect.maxY - p.y * rect.height)
            }
            for loop in glyph.outline {
                guard let first = loop.first else { continue }
                path.move(to: point(first))
                for p in loop.dropFirst() { path.line(to: point(p)) }
                path.close()
            }
            ink.setFill()
            path.fill()
        }
    }
}
