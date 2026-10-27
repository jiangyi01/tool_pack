import Cocoa

/// Draws the hidden icons in one row (wrapping if needed), the way the menu bar would.
@MainActor
final class StripView: NSView {
    struct Cell {
        let item: BarItem
        let image: NSImage?
        let rect: NSRect
    }

    static let rowHeight: CGFloat = 28
    static let padding: CGFloat = 4
    static let inset: CGFloat = 8         // space either side of a fallback icon
    static let iconSize: CGFloat = 16
    static let footerHeight: CGFloat = 20

    private(set) var cells: [Cell] = []
    private var message: String?
    private var footer: String?
    var hoverIndex: Int? { didSet { if oldValue != hoverIndex { needsDisplay = true } } }
    var openIndex: Int? { didSet { if oldValue != openIndex { needsDisplay = true } } }
    var onClick: ((Int, Clicker.Button) -> Void)?
    var onPress: ((Int) -> Void)?       // mouse went down on a cell (decisions belong to this moment)
    var messageAction: (() -> Void)?
    private var pressed: (index: Int, right: Bool)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let font = NSFont.menuBarFont(ofSize: 0)
    private static let footerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    /// Lays out the content and returns the size the panel should take.
    func setContent(items: [BarItem], images: [String: NSImage], message: String?, footer: String?,
                    maxWidth: CGFloat) -> NSSize {
        self.message = message
        self.footer = footer
        let p = Self.padding, h = Self.rowHeight
        var size: NSSize
        if let message {
            cells = []
            let w = (message as NSString).size(withAttributes: [.font: Self.font]).width
            size = NSSize(width: ceil(w) + 28, height: h + 2 * p)
        } else {
            // One row like the menu bar; when it can't fit, rows of roughly equal width.
            let widths = items.map { Self.width(of: $0, image: images[$0.id]) }
            let total = widths.reduce(0, +)
            let rows = max(1, Int(ceil(total / max(maxWidth - 2 * p, 1))))
            let limit = rows == 1 ? CGFloat.infinity
                : min(total / CGFloat(rows) + 0.5 * (widths.max() ?? 0), maxWidth - 2 * p)
            var x = p, y = p, widest: CGFloat = 0
            var out: [Cell] = []
            for (item, w) in zip(items, widths) {
                if x > p && x - p + w > limit { x = p; y += h }
                out.append(Cell(item: item, image: images[item.id], rect: NSRect(x: x, y: y, width: w, height: h)))
                x += w
                widest = max(widest, x)
            }
            cells = out
            size = NSSize(width: widest + p, height: y + h + p)
        }
        if let footer {
            let fw = (footer as NSString).size(withAttributes: [.font: Self.footerFont]).width
            let w = min(max(size.width, ceil(fw) + 20), maxWidth)
            // The panel is right-anchored under 📦: keep the cells where they were, so a
            // resting pointer stays on the same icon.
            let dx = w - size.width
            if dx > 0 { cells = cells.map { Cell(item: $0.item, image: $0.image, rect: $0.rect.offsetBy(dx: dx, dy: 0)) } }
            size.width = w
            size.height += Self.footerHeight
        }
        return size
    }

    func index(atScreen p: NSPoint) -> Int? {
        guard let window else { return nil }
        let local = convert(window.convertPoint(fromScreen: p), from: nil)
        return cells.firstIndex { $0.rect.contains(local) }
    }

    private func index(of e: NSEvent) -> Int? {
        let local = convert(e.locationInWindow, from: nil)
        return cells.firstIndex { $0.rect.contains(local) }
    }

    // MARK: Mouse — act on release, like a button, so the user's finger is up before
    // anything (including a synthesized click) happens.

    override func mouseDown(with e: NSEvent) {
        guard e.clickCount == 1 else { pressed = nil; return }   // a double-click is one intent
        pressed = index(of: e).map { ($0, e.modifierFlags.contains(.control)) }
        if let p = pressed { onPress?(p.index) }
    }

    override func mouseUp(with e: NSEvent) {
        if message != nil { messageAction?(); return }
        defer { pressed = nil }
        guard let p = pressed, index(of: e) == p.index else { return }
        onClick?(p.index, p.right ? .right : e.modifierFlags.contains(.option) ? .option : .left)
    }

    override func rightMouseDown(with e: NSEvent) {
        guard e.clickCount == 1 else { pressed = nil; return }
        pressed = index(of: e).map { ($0, true) }
        if let p = pressed { onPress?(p.index) }
    }

    override func rightMouseUp(with e: NSEvent) {
        defer { pressed = nil }
        guard let p = pressed, index(of: e) == p.index else { return }
        onClick?(p.index, .right)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let message {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]
            let s = (message as NSString).size(withAttributes: attrs)
            let top = (footer == nil ? bounds.height : bounds.height - Self.footerHeight)
            (message as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: ((top - s.height) / 2).rounded()),
                                       withAttributes: attrs)
        }
        for (i, c) in cells.enumerated() {
            if i == openIndex || i == hoverIndex {
                NSColor.labelColor.withAlphaComponent(i == openIndex ? 0.2 : 0.1).setFill()
                NSBezierPath(roundedRect: c.rect.insetBy(dx: 0.5, dy: 2), xRadius: 6, yRadius: 6).fill()
            }
            if let img = c.image {
                // Native size, centred: slots are as tall as their display's menu bar (24–33pt);
                // the extra height is transparent padding, so clip it instead of scaling.
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: c.rect).addClip()
                let r = NSRect(x: (c.rect.midX - img.size.width / 2).rounded(), y: (c.rect.midY - img.size.height / 2).rounded(),
                               width: img.size.width, height: img.size.height)
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                drawFallback(c)
            }
        }
        if let footer {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.footerFont, .foregroundColor: NSColor.secondaryLabelColor]
            let r = NSRect(x: 10, y: bounds.height - Self.footerHeight, width: bounds.width - 20, height: Self.footerHeight - 4)
            (footer as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }

    /// Without Screen Recording: a symbol or the app icon, plus the item's own text (e.g. "971").
    private func drawFallback(_ c: Cell) {
        let f = Self.fallback(for: c.item)
        var x = c.rect.minX + Self.inset
        if let icon = f.icon {
            if f.template {
                let s = icon.size
                let r = NSRect(x: x, y: (c.rect.midY - s.height / 2).rounded(), width: s.width, height: s.height)
                let tinted = NSImage(size: s, flipped: false) { rr in
                    icon.draw(in: rr)
                    NSColor.labelColor.set()
                    rr.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: r)
                x = r.maxX + 4
            } else {
                let side = Self.iconSize
                let r = NSRect(x: x, y: (c.rect.midY - side / 2).rounded(), width: side, height: side)
                icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x = r.maxX + 4
            }
        }
        if let text = f.text {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.labelColor]
            let s = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: x, y: (c.rect.midY - s.height / 2).rounded()), withAttributes: attrs)
        }
    }

    private static func width(of item: BarItem, image: NSImage?) -> CGFloat {
        if let image, image.size.width > 0 { return max(ceil(image.size.width), rowHeight) }
        let f = fallback(for: item)
        var w = 2 * inset
        if let icon = f.icon { w += f.template ? ceil(icon.size.width) : iconSize }
        if let text = f.text {
            w += (f.icon != nil ? 4 : 0) + ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        return max(w, rowHeight)
    }

    private static let symbols: [(String, String)] = [
        ("battery", "battery.75percent"), ("wifi", "wifi"), ("sound", "speaker.wave.2.fill"),
        ("volume", "speaker.wave.2.fill"), ("focus", "moon.fill"), ("display", "sun.max.fill"),
        ("spotlight", "magnifyingglass"), ("nowplaying", "play.circle"), ("textinput", "keyboard"),
        ("screenmirroring", "rectangle.on.rectangle"), ("timemachine", "clock.arrow.circlepath"),
        ("controlcenter", "switch.2"), ("bluetooth", "dot.radiowaves.left.and.right"),
    ]

    private static func fallback(for item: BarItem) -> (icon: NSImage?, template: Bool, text: String?) {
        if item.isSystem {
            let key = item.identifier.lowercased()
            for (needle, name) in symbols where key.contains(needle) {
                if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
                    return (img, true, nil)
                }
            }
        }
        // Only what the item itself shows in the menu bar (a count, a status) — never its
        // description, which can be long and multi-line.
        return (item.appIcon, false, shortText(item.title))
    }

    private static func shortText(_ s: String) -> String? {
        let line = s.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 16 ? String(line.prefix(15)) + "…" : line
    }
}

/// Keeps the hairline border right in both light and dark appearance.
private final class StripBackground: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    func updateBorder() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.12 : 0.35).cgColor
    }
}

/// The floating strip under 📦. Non-activating and never key, so it can't steal focus.
@MainActor
final class StripPanel: NSPanel {
    let strip = StripView()
    private let effect = StripBackground()
    private var anchor: CGRect = .zero
    private(set) var isShown = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        canHide = false

        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        strip.autoresizingMask = [.width, .height]
        effect.addSubview(strip)
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `anchor` is the 📦 slot (CG). The strip hangs below it, right-aligned.
    /// `dark` follows the captured icons (white glyphs need a dark strip); nil = system.
    func present(items: [BarItem], images: [String: NSImage], message: String?, messageAction: (() -> Void)?,
                 footer: String?, anchor: CGRect, dark: Bool?) {
        self.anchor = anchor
        appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        effect.updateBorder()
        strip.messageAction = messageAction

        let a = Geo.toAppKit(anchor)
        let screen = NSScreen.screens.first { NSPointInRect(NSPoint(x: a.midX, y: a.midY - 1), $0.frame) } ?? NSScreen.main
        let sf = screen?.frame ?? .zero
        let size = strip.setContent(items: items, images: images, message: message, footer: footer,
                                    maxWidth: min(760, sf.width * 0.5))
        var x = a.maxX - size.width
        x = min(max(x, sf.minX + 8), sf.maxX - size.width - 8)
        let frame = NSRect(x: x, y: a.minY - 5 - size.height, width: size.width, height: size.height)
        setFrame(frame, display: true)
        strip.frame = NSRect(origin: .zero, size: size)
        strip.needsDisplay = true

        isShown = true
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
        }
        // Also cancels a fade-out that is still running.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.orderOut(nil)
            }
        })
    }

    /// The panel plus the 📦 above it and the gap between them (CG).
    var zone: CGRect { Geo.toCG(frame).union(anchor).insetBy(dx: -6, dy: -6) }

    /// Lets a popover that opened underneath the strip come to the front.
    func lower(below window: CGWindowID, layer: Int) {
        level = NSWindow.Level(rawValue: layer)
        order(.below, relativeTo: Int(window))
    }

    func raise() {
        guard level != .popUpMenu else { return }
        level = .popUpMenu
        if isShown { orderFrontRegardless() }
    }
}
