import Cocoa

/// The 📦 in the menu bar — LittleBox's only status item. It never hides other icons.
@MainActor
final class StatusController: NSObject {
    static let name = "LittleBox.Box"

    private(set) var item: NSStatusItem
    var onClick: ((CGRect) -> Void)?
    var onRightClick: (() -> Void)?

    private var copies: [CGRect] = []          // visible 📦 slots on every display (CG)
    private var copiesAt = Date.distantPast
    private var matched = false                 // the window server knows our slot
    private var copyIDs: [CGWindowID] = []

    override init() {
        let d = UserDefaults.standard
        // First run: far right, so the notch can never swallow the box itself.
        let key = "NSStatusItem Preferred Position \(Self.name)"
        if d.object(forKey: key) == nil { d.set(0.0, forKey: key) }
        d.set(true, forKey: "NSStatusItem Visible \(Self.name)")
        // Leftovers from earlier versions.
        for k in ["NSStatusItem Preferred Position LittleBox.Divider", "NSStatusItem Visible LittleBox.Divider",
                  "autoCollapse", "onboarded", "actionItems"] {
            d.removeObject(forKey: k)
        }

        item = Self.makeItem()
        super.init()
        configure()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.copiesAt = .distantPast }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.copiesAt = .distantPast }
        }
    }

    private static func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name
        item.behavior = []
        return item
    }

    private func configure() {
        guard let b = item.button else { return }
        b.image = Self.image(open: false)
        b.target = self
        b.action = #selector(clicked)
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Puts 📦 back at the far right (recovery when the system has hidden it).
    func resetPosition() {
        NSStatusBar.system.removeStatusItem(item)
        UserDefaults.standard.set(0.0, forKey: "NSStatusItem Preferred Position \(Self.name)")
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(Self.name)")
        item = Self.makeItem()
        configure()
        copiesAt = .distantPast
    }

    static func image(open: Bool) -> NSImage? {
        let img = NSImage(systemSymbolName: open ? "shippingbox.fill" : "shippingbox", accessibilityDescription: "LittleBox")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        img?.isTemplate = true
        return img
    }

    func setOpen(_ open: Bool) { item.button?.image = Self.image(open: open) }

    @objc private func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            onRightClick?()
            return
        }
        let p = Geo.toCG(point: NSEvent.mouseLocation)
        if let f = frame(containing: p) {
            onClick?(f)
        } else if let s = Geo.screen(containing: p) {
            // Not in the cache yet: hang the strip from the click point on that display.
            let sf = Geo.cgFrame(s), m = mainFrame
            onClick?(CGRect(x: p.x - max(m.width, 24) / 2, y: sf.minY, width: max(m.width, 24),
                            height: max(m.height, NSStatusBar.system.thickness)))
        } else {
            onClick?(mainFrame)
        }
    }

    func show(menu: NSMenu) {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// The 📦 window this process owns (CG coordinates).
    var mainFrame: CGRect { item.button?.window.map { Geo.toCG($0.frame) } ?? .zero }

    /// The visible 📦 slot under `p` on any display's menu bar. Called on every mouse
    /// move in a menu bar, so a miss only re-reads our own few windows (cheap); the full
    /// window list (~25 ms) is read at most every 3 s or when our windows changed.
    func frame(containing p: CGPoint) -> CGRect? {
        let age = Date().timeIntervalSince(copiesAt)
        if age > 3 { refreshCopies() }
        if let f = hit(p) { return f }
        if age > 0.5 && age <= 3 {
            if !rereadCopies() { refreshCopies() }
            return hit(p)
        }
        return nil
    }

    private func rereadCopies() -> Bool {
        guard matched, !copyIDs.isEmpty else { return false }
        var out: [CGRect] = []
        for id in copyIDs {
            guard let i = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
                  let b = i[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { return false }   // gone: full refresh
            if (i[kCGWindowIsOnscreen as String] as? Bool) == true { out.append(r) }
        }
        copies = out
        copiesAt = Date()
        return true
    }

    private func hit(_ p: CGPoint) -> CGRect? { copies.first { $0.insetBy(dx: 0, dy: -2).contains(p) } }

    private func refreshCopies() {
        copiesAt = Date()
        copies = []
        let main = mainFrame
        let ws = WindowServer.statusWindows()
        if let w = WindowServer.match(main, in: ws) {
            matched = true
            let all = WindowServer.copies(of: w, in: WindowServer.rows(ws))
            copyIDs = all.map(\.id)
            copies = all.filter(\.onScreen).map(\.frame)
        } else {
            // No window-server data (older systems): trust our own window.
            matched = false
            copyIDs = []
            if main != .zero { copies = [main] }
        }
    }

    /// False when the system has hidden 📦 itself on every display (e.g. behind the notch).
    var isVisibleSomewhere: Bool {
        refreshCopies()
        return !matched || !copies.isEmpty
    }
}
