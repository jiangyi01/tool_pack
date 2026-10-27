@preconcurrency import ApplicationServices
import Cocoa
import os

/// The record of what is open, touched only on the AX queue.
private final class AXWorker: @unchecked Sendable {
    var last: OpenRecord?
}

/// Shows the icons a display's menu bar can't fit, and opens their own menus.
///
/// Hover flow: point at 📦 → the strip drops down → rest on an icon → its real menu or
/// popover opens → slide to another icon → it switches, like the menu bar itself.
@MainActor
final class BoxController {
    private let status: StatusController
    private let panel = StripPanel()
    private let axQueue = DispatchQueue(label: "littlebox.ax", qos: .userInteractive)
    private let worker = AXWorker()
    private let axGen = OSAllocatedUnfairLock(initialState: 0)

    // Scan cache
    private var items: [BarItem] = []
    private var scannedScreen: CGRect?
    private var images: [String: NSImage] = [:]   // by item.id
    private var lums: [String: CGFloat] = [:]
    private var lastScan = Date.distantPast
    private var scanning = false
    private var pending: [() -> Void] = []

    // Strip session
    private(set) var isOpen = false
    private var session = 0
    private var openedByHover = false
    private var anchor: CGRect = .zero
    private var emptyHoverAnchor: CGRect?       // 📦 slot where a hover found nothing to show
    private var openTimer: Timer?
    private var poll: Timer?
    private var activePoll: Timer?
    private var ticks = 0
    private var outsideSince: Date?
    private var footer: String?
    private var footerUntil: Date?
    private var clickMonitor: Any?
    private var lastPoint = CGPoint.zero
    private var lastPointAt = Date.distantPast
    private var velocity = CGVector.zero
    private var relayoutPoint: NSPoint?          // pointer position when the cells last moved

    // The item whose menu we opened
    private var gen = 0
    private var openItem: BarItem?
    private var openByHover = false
    private var openedAt = Date.distantPast
    private var pressStartedAt: Date?
    private var pressEndedAt: Date?
    private var pressResult: PressResult?
    private var baseline: Set<CGWindowID>?
    private var openIDs = Set<CGWindowID>()      // windows this press was seen to show
    private var sawMenu = false
    private var openWindows: [CGRect] = []
    private var userActed = false                // any click/key since the press (learning guard)
    private var interacted = false               // same, but stops adopting new windows
    private var fallbackTried = false
    private var lowered = false
    private var downOnOpen = false
    private var misses: [String: Int] = [:]
    private var electronCache: [pid_t: Bool] = [:]   // Clicker.isElectron hits the filesystem

    // Hover
    private var dwellID: String?
    private var dwellStart = Date.distantPast
    private var rearmBlock: String?     // a cell that must be left before hover can open it

    var onNeedsPermission: (() -> Void)?

    private var recentlyOpened: Bool { Date().timeIntervalSince(openedAt) < 0.8 }

    /// Electron trays accept AXPress but ignore it; cached per pid.
    private func isElectron(_ pid: pid_t) -> Bool {
        if let e = electronCache[pid] { return e }
        let e = Clicker.isElectron(pid)
        electronCache[pid] = e
        return e
    }

    init(status: StatusController) {
        self.status = status
        status.onClick = { [weak self] frame in self?.clicked(anchor: frame) }
        panel.strip.onClick = { [weak self] i, b in self?.cellClicked(i, button: b) }
        panel.strip.onPress = { [weak self] i in
            guard let self, i < self.panel.strip.cells.count else { return }
            let item = self.panel.strip.cells[i].item
            self.downOnOpen = self.sawMenu && (self.openItem.map { CFEqual($0.element, item.element) } ?? false)
        }

        _ = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        _ = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }
        // While our own Settings window is frontmost, mouse-moved events may not reach the
        // monitors; poll gently instead.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activePoll == nil else { return }
                self.activePoll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.mouseMoved() }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activePoll?.invalidate(); self?.activePoll = nil }
        }
    }

    // MARK: Opening the strip

    private func mouseMoved() {
        guard !isOpen else { return }   // the poll timer takes over while open
        guard NSEvent.pressedMouseButtons == 0, Geo.mouseInMenuBar else { cancelOpenTimer(); return }
        let p = Geo.toCG(point: NSEvent.mouseLocation)
        let box = status.frame(containing: p)
        if box == nil { emptyHoverAnchor = nil }
        // Warm the cache while the pointer is in a real menu bar, so the strip opens instantly.
        if Date().timeIntervalSince(lastScan) > 2, let s = Geo.screen(containing: p), Geo.menuBarHeight(s) > 0 || box != nil {
            scan(screen: Geo.cgFrame(s))
        }
        guard Prefs.hoverOpen, let box, box != emptyHoverAnchor else { cancelOpenTimer(); return }
        guard openTimer == nil else { return }
        openTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.openTimer = nil
                guard NSEvent.pressedMouseButtons == 0,
                      let f = self.status.frame(containing: Geo.toCG(point: NSEvent.mouseLocation)) else { return }
                self.open(anchor: f, byHover: true)
            }
        }
    }

    private func cancelOpenTimer() { openTimer?.invalidate(); openTimer = nil }

    private func clicked(anchor: CGRect) {
        if isOpen {
            if Prefs.hoverOpen { openedByHover = false; render() } else { close() }
        } else {
            emptyHoverAnchor = nil
            open(anchor: anchor, byHover: false)
        }
    }

    func open(anchor: CGRect, byHover: Bool) {
        cancelOpenTimer()
        if !isOpen {
            isOpen = true
            session &+= 1
            openedByHover = byHover
            outsideSince = nil
            footer = nil
        } else if !byHover {
            openedByHover = false
        }
        self.anchor = anchor
        status.setOpen(true)
        startPoll()
        installClickMonitor()
        guard AXIsProcessTrusted() else {
            panel.present(items: [], images: [:],
                          message: t("需要辅助功能权限 · 点此设置", "Accessibility access needed · Click to set up"),
                          messageAction: { [weak self] in self?.close(); self?.onNeedsPermission?() },
                          footer: nil, anchor: anchor, dark: nil)
            return
        }
        let s = session
        let screen = Geo.screen(containing: CGPoint(x: anchor.midX, y: anchor.midY)).map(Geo.cgFrame)
        let fresh = scannedScreen == screen && Date().timeIntervalSince(lastScan) < 2
        if scannedScreen == screen && (fresh || !items.isEmpty) { render() }   // stale is fine; refreshed below
        guard isOpen, !fresh else { return }   // render() may have closed an empty hover
        scan(screen: screen) { [weak self] in
            guard let self, self.isOpen, self.session == s else { return }
            if self.scannedScreen != screen {
                self.scan(screen: screen) { [weak self] in
                    guard let self, self.isOpen, self.session == s else { return }
                    self.render()
                }
            } else {
                self.render()
            }
        }
    }

    func close() {
        cancelOpenTimer()
        poll?.invalidate(); poll = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        isOpen = false
        panel.dismiss()
        panel.raise()
        status.setOpen(false)
        dwellID = nil
        rearmBlock = nil
        outsideSince = nil
        relayoutPoint = nil
        panel.strip.hoverIndex = nil
        // A press still waiting in the queue must not fire after the strip is gone.
        gen &+= 1
        let g = gen
        axGen.withLock { $0 = g }
        // Forget what we opened on this side; the AX worker keeps its record (with the
        // windows it showed), so the next open can still close it.
        endOpen(learn: false, block: false)
    }

    private func render() {
        guard isOpen, poll != nil else { return }
        let boxed = items.filter(\.hidden)
        if boxed.isEmpty && openedByHover {
            emptyHoverAnchor = anchor   // don't loop open → scan → close while resting on 📦
            close()
            return
        }
        if let until = footerUntil, Date() > until { footer = nil; footerUntil = nil }
        let message = boxed.isEmpty ? t("所有图标都在菜单栏上", "Everything fits in the menu bar") : nil
        let l = boxed.compactMap { lums[$0.id] }.sorted()
        let before = panel.strip.cells.map(\.rect)
        panel.present(items: boxed, images: images, message: message, messageAction: nil, footer: footer,
                      anchor: anchor, dark: l.isEmpty ? nil : l[l.count / 2] > 0.6)
        panel.strip.openIndex = openItem.flatMap { o in panel.strip.cells.firstIndex { CFEqual($0.item.element, o.element) } }
        if panel.strip.cells.map(\.rect) != before { relayoutPoint = NSEvent.mouseLocation }
    }

    private func showFooter(_ text: String) {
        footer = text
        footerUntil = Date().addingTimeInterval(4)
        render()
    }

    // MARK: Scanning

    private func scan(screen: CGRect?, completion: (() -> Void)? = nil) {
        if let completion { pending.append(completion) }
        guard AXIsProcessTrusted() else {
            let p = pending; pending = []; p.forEach { $0() }
            return
        }
        guard !scanning else { return }
        scanning = true
        let apps = AppInfo.running()
        let canCapture = CGPreflightScreenCaptureAccess() && IconCapture.isAvailable
        let notch = NSScreen.screens.first { Geo.cgFrame($0) == screen }.flatMap(Geo.notch)
        let previous = items
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Scanner.snapshot(apps: apps, screen: screen, notch: notch, previous: previous)
            var caps: [String: (NSImage, CGFloat?)] = [:]
            if canCapture {
                for item in found where item.hidden {
                    if let c = IconCapture.capture(item) { caps[item.id] = c }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.items = found
                    self.scannedScreen = screen
                    let live = Set(found.map(\.id))
                    self.images = self.images.filter { live.contains($0.key) }
                    self.lums = self.lums.filter { live.contains($0.key) }
                    for (k, v) in caps {
                        self.images[k] = v.0
                        if let l = v.1 { self.lums[k] = l }
                    }
                    self.lastScan = Date()
                    self.scanning = false
                    let p = self.pending
                    self.pending = []
                    p.forEach { $0() }
                }
            }
        }
    }

    // MARK: While the strip is open

    private func startPoll() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Clicks that never reach the strip: while another app's menu is tracking, it takes
    /// the click (and closes its menu). Everything is decided at mouse-down time.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.userActed = true
                self.interacted = true
                guard e.type != .keyDown, let open = self.openItem, self.panel.isShown else { return }
                let p = Geo.toCG(point: NSEvent.mouseLocation)
                // A click inside our own menu or popover is for the menu, never for a cell beneath it.
                guard !self.openWindows.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(p) }),
                      let i = self.panel.strip.index(atScreen: NSEvent.mouseLocation),
                      i < self.panel.strip.cells.count else { return }
                let target = self.panel.strip.cells[i].item
                let wasThis = CFEqual(open.element, target.element)
                let g = self.gen
                let recent = self.recentlyOpened
                let button: Clicker.Button = (e.type == .rightMouseDown || e.modifierFlags.contains(.control)) ? .right
                    : e.modifierFlags.contains(.option) ? .option : .left
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.swallowedClick(target, wasThis: wasThis, gen: g, recent: recent, button: button)
                    }
                }
            }
        }
    }

    private func tick() {
        guard isOpen else { return }
        ticks += 1
        let now = Date()
        let mouse = NSEvent.mouseLocation
        let p = Geo.toCG(point: mouse)
        let dt = now.timeIntervalSince(lastPointAt)
        if dt > 0 && dt < 0.5 {
            velocity = CGVector(dx: (p.x - lastPoint.x) / dt, dy: (p.y - lastPoint.y) / dt)
        }
        lastPoint = p
        lastPointAt = now
        if let until = footerUntil, now > until { footer = nil; footerUntil = nil; render() }

        trackOpenMenu(now)
        guard isOpen else { return }

        // Close once the pointer has been away from the strip (and from our menu) for a moment.
        // Before the first present, allow for where the strip is about to appear.
        let zone = panel.isShown ? panel.zone
            : anchor.union(CGRect(x: anchor.maxX - 420, y: anchor.maxY, width: 420, height: 90)).insetBy(dx: -6, dy: -6)
        let overMenu = openItem != nil && openWindows.contains { $0.insetBy(dx: -8, dy: -8).contains(p) }
        if zone.contains(p) || overMenu {
            outsideSince = nil
        } else if let since = outsideSince {
            if now.timeIntervalSince(since) > 0.4 { close(); return }
        } else {
            outsideSince = now
        }

        // Hover highlight, and hover-to-open after a short rest.
        guard panel.isShown, NSEvent.pressedMouseButtons == 0 else {
            dwellID = nil
            panel.strip.hoverIndex = nil
            return
        }
        // The cells just moved under a still pointer: wait for a real movement.
        if let rp = relayoutPoint {
            if hypot(mouse.x - rp.x, mouse.y - rp.y) < 3 { dwellID = nil; return }
            relayoutPoint = nil
        }
        let idx = overMenu ? nil : panel.strip.index(atScreen: mouse)
        panel.strip.hoverIndex = idx
        if idx == nil && !overMenu { rearmBlock = nil }
        guard Prefs.hoverOpen, let idx, idx < panel.strip.cells.count else { dwellID = nil; return }
        let item = panel.strip.cells[idx].item
        if let b = rearmBlock {
            if b == item.id { dwellID = nil; return }
            rearmBlock = nil
        }
        if let o = openItem, CFEqual(o.element, item.element) { dwellID = nil; return }
        if !item.isMenuHost, Prefs.actionItems.contains(item.stableKey) { dwellID = nil; return }
        if aimingAtMenu(p) { dwellID = nil; return }
        if dwellID != item.id {
            dwellID = item.id
            dwellStart = now
            return
        }
        let settled = pressStartedAt.map { now.timeIntervalSince($0) > 0.25 } ?? true
        if settled && now.timeIntervalSince(dwellStart) >= (openItem == nil ? 0.22 : 0.12) {
            dwellID = nil
            if isElectron(item.pid) {
                // Electron trays ignore AXPress, and a real click would move the pointer:
                // say so once per dwell instead of pressing.
                rearmBlock = item.id
                showFooter(t("「\(item.appName)」需要点击打开", "Click to open \(item.appName)"))
                return
            }
            openMenu(item, button: .left, byHover: true)
        }
    }

    /// The pointer is heading for the open menu: don't switch menus on the cells it crosses.
    private func aimingAtMenu(_ p: CGPoint) -> Bool {
        guard openItem != nil, let first = openWindows.first else { return false }
        let target = openWindows.dropFirst().reduce(first) { $0.union($1) }
        let to = CGVector(dx: target.midX - p.x, dy: target.midY - p.y)
        let speed = hypot(velocity.dx, velocity.dy)
        return speed > 80 && velocity.dx * to.dx + velocity.dy * to.dy > 0
    }

    /// Follows the windows our press produced: menu-like windows that weren't on screen
    /// before it. Windows that appear after the user starts using the menu (a window
    /// opened from it, say) are never adopted.
    private func trackOpenMenu(_ now: Date) {
        guard let o = openItem, let base = baseline, let started = pressStartedAt else { return }
        let early = now.timeIntervalSince(started) < 1.0
        guard early || ticks % 3 == 0 else { return }
        let all = WindowServer.openUI(pid: o.pid).filter { !base.contains($0.id) }
        let menuLike = all.filter { WindowServer.isMenuLike($0, pid: o.pid, system: o.isMenuHost) }
        if !interacted {
            let new = Set(menuLike.map(\.id)).subtracting(openIDs)
            if !new.isEmpty {
                openIDs.formUnion(new)
                let g = gen, ids = openIDs
                axQueue.async { [worker] in if worker.last?.gen == g { worker.last?.windows = ids } }
            }
        }
        let live = all.filter { openIDs.contains($0.id) }
        openWindows = live.map(\.frame)
        adjustLevel(live)

        if !live.isEmpty {
            if !sawMenu {
                EventLog.write("shown  \(o.appName) [\(o.stableKey)] windows=\(live.count) \(Self.describe(live[0]))")
            }
            sawMenu = true
            misses[o.stableKey] = nil
            if Prefs.actionItems.contains(o.stableKey) { Prefs.actionItems.remove(o.stableKey) }
        } else if sawMenu {
            EventLog.write("closed \(o.appName)")
            forgetRecord(gen)
            endOpen(learn: false, block: true)
        } else if menuLike.isEmpty, all.contains(where: { $0.owner == o.pid }), pressResult != nil,
                  let ended = pressEndedAt, now.timeIntervalSince(ended) >= 0.8 {
            // The press opened an ordinary app window: it is an action, not a menu. (Wait a
            // moment first: some apps flash a stray window before their real popover.)
            let wins = all.filter { $0.owner == o.pid }.map { Self.describe($0) }.joined(separator: "; ")
            EventLog.write("window \(o.appName): action, not a menu \(wins)")
            endOpen(learn: openByHover && !userActed, block: true)
        } else if pressResult == .sent, !openByHover, !fallbackTried, let ended = pressEndedAt,
                  now.timeIntervalSince(ended) > 0.6, isElectron(o.pid) {
            electronFallback(o)
        } else if pressResult == .sent, let ended = pressEndedAt, now.timeIntervalSince(ended) > 1.5 {
            // Nothing appeared. Only an uninterrupted hover counts towards "this is an action
            // button"; it takes two such misses before hover stops opening it.
            endOpen(learn: openByHover && !userActed, block: true)
        } else if now.timeIntervalSince(started) > 3 {
            endOpen(learn: false, block: true)
        }
    }

    /// Electron trays accept AXPress but ignore it; on a click, press their visible copy for real.
    private func electronFallback(_ o: BarItem) {
        fallbackTried = true
        pressEndedAt = Date()
        let g = gen, ids = o.copies.map(\.id), name = o.appName
        axQueue.async { [axGen, weak self] in
            guard axGen.withLock({ $0 }) == g else { return }
            if let slot = WindowServer.visibleCopy(ids) {
                Clicker.click(slot, button: .left)
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.showFooter(Self.hiddenHint(name)) }
                }
            }
        }
    }

    nonisolated private static func describe(_ w: UIWindow) -> String {
        let f = w.frame
        return "layer=\(w.layer) frame=(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))) name=\"\(w.name)\""
    }

    private static func hiddenHint(_ name: String) -> String {
        t("「\(name)」被挡住时无法直接打开 · 可按住 ⌘ 把它拖到菜单栏右侧",
          "\(name) can't be opened while hidden · ⌘-drag it further right in the menu bar")
    }

    /// Lets a popover that opened underneath the strip show above it.
    private func adjustLevel(_ live: [UIWindow]) {
        let strip = Geo.toCG(panel.frame)
        if panel.isShown, let w = live.first(where: { $0.layer < WindowServer.popUpMenuLayer && $0.frame.intersects(strip) }) {
            if !lowered { panel.lower(below: w.id, layer: w.layer); lowered = true }
        } else if lowered {
            panel.raise()
            lowered = false
        }
    }

    private func forgetRecord(_ g: Int) {
        axQueue.async { [worker] in if worker.last?.gen == g { worker.last = nil } }
    }

    private func endOpen(learn: Bool, block: Bool) {
        if let o = openItem {
            if learn, !o.isMenuHost {   // Apple's own items are never click-only
                let n = (misses[o.stableKey] ?? 0) + 1
                misses[o.stableKey] = n
                EventLog.write("nothing appeared for \(o.appName) (\(n)/2)")
                if n >= 2 {
                    Prefs.actionItems.insert(o.stableKey)
                    misses[o.stableKey] = nil
                    EventLog.write("learned click-only: \(o.appName) [\(o.stableKey)]")
                }
            }
            if block {
                // Block the cell under the pointer (a menu may have covered a different one).
                let under = panel.strip.index(atScreen: NSEvent.mouseLocation)
                    .flatMap { $0 < panel.strip.cells.count ? panel.strip.cells[$0].item.id : nil }
                rearmBlock = under ?? o.id
            }
        }
        openItem = nil
        baseline = nil
        pressStartedAt = nil
        pressEndedAt = nil
        pressResult = nil
        sawMenu = false
        openIDs = []
        openWindows = []
        fallbackTried = false
        if lowered { panel.raise(); lowered = false }
        panel.strip.openIndex = nil
    }

    // MARK: Using an item

    private func cellClicked(_ i: Int, button: Clicker.Button) {
        guard i < panel.strip.cells.count else { return }
        let item = panel.strip.cells[i].item
        let wasOpen = downOnOpen
        downOnOpen = false
        userActed = true
        let openNow = openItem.map { CFEqual($0.element, item.element) } ?? false
        if button == .left && (wasOpen || openNow) {
            if openNow && recentlyOpened {
                openByHover = false   // the click confirms what hover just opened
                return
            }
            if openNow {
                guard sawMenu else { return }   // still opening: a click must not toggle it shut
                let g = gen
                endOpen(learn: false, block: true)
                axQueue.async { [worker] in
                    if let r = worker.last, r.gen == g { Clicker.dismiss(r); worker.last = nil }
                }
            } else {
                rearmBlock = item.id   // it already closed when the mouse went down
            }
            return
        }
        interacted = true
        openMenu(item, button: button, byHover: false)
    }

    /// The user's click went to the open menu's app, which closed that menu.
    private func swallowedClick(_ item: BarItem, wasThis: Bool, gen g: Int, recent: Bool, button: Clicker.Button) {
        guard isOpen else { return }
        if wasThis {
            if gen == g {
                forgetRecord(g)
                endOpen(learn: false, block: !recent)
            }
            // A reflexive click right after hover opened it meant "open": bring it back.
            if recent { openMenu(item, button: button, byHover: false) } else { rearmBlock = item.id }
            return
        }
        openMenu(item, button: button, byHover: false)
    }

    private func openMenu(_ item: BarItem, button: Clicker.Button, byHover: Bool) {
        gen &+= 1
        let g = gen
        axGen.withLock { $0 = g }
        endOpen(learn: false, block: false)
        // Electron trays ignore AXPress: a click goes straight to a real click on the copy
        // (never on hover — a synthetic click moves the pointer).
        let electron = !byHover && isElectron(item.pid)
        fallbackTried = electron   // the real click is already the fallback
        openItem = item
        openByHover = byHover
        openedAt = Date()
        userActed = !byHover
        interacted = false
        panel.strip.openIndex = panel.strip.cells.firstIndex { CFEqual($0.item.element, item.element) }
        EventLog.write("open   \(item.appName) [\(item.stableKey)] \(byHover ? "hover" : "click") \(button)\(electron ? " electron" : "")")

        let el = item.element, pid = item.pid
        let copyIDs = item.copies.map(\.id)
        axQueue.async { [worker, axGen, weak self] in
            if let r = worker.last {
                Clicker.dismiss(r)
                worker.last = nil
                usleep(80_000)
            }
            guard axGen.withLock({ $0 }) == g else { return }   // superseded, or the strip closed
            if byHover && Clicker.isBusy(el) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.pressFinished(g, .busy) } }
                return
            }
            let before = WindowServer.onScreenIDs()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pressStarted(g, baseline: before) } }

            var result: PressResult
            if electron {
                if let slot = WindowServer.visibleCopy(copyIDs) {
                    Clicker.click(slot, button: button)
                    result = .sent
                } else {
                    // Hidden everywhere: AXPress is the only option left (some Electron trays answer it).
                    result = Clicker.open(el, pid: pid, button: button)
                }
            } else if button == .option, let slot = WindowServer.visibleCopy(copyIDs) {
                Clicker.click(slot, button: .option)
                result = .sent
            } else {
                result = Clicker.open(el, pid: pid, button: button)
            }
            // The app ignores Accessibility actions: click a copy that is on screen, if any
            // (never on hover — a synthetic click moves the pointer).
            if result == .failed, !byHover, let slot = WindowServer.visibleCopy(copyIDs) {
                Clicker.click(slot, button: button)
                result = .sent
            }
            if result != .failed {
                worker.last = OpenRecord(gen: g, element: el, pid: pid, button: button, baseline: before, pressedAt: Date())
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pressFinished(g, result) } }
        }
    }

    private func pressStarted(_ g: Int, baseline: Set<CGWindowID>) {
        guard g == gen else { return }
        self.baseline = baseline
        pressStartedAt = Date()
    }

    private func pressFinished(_ g: Int, _ result: PressResult) {
        guard g == gen else { return }
        pressResult = result
        pressEndedAt = Date()
        EventLog.write("result \(openItem?.appName ?? "?") \(result)")
        switch result {
        case .failed:
            let name = openItem?.appName ?? ""
            endOpen(learn: false, block: true)
            showFooter(Self.hiddenHint(name))
        case .busy:
            endOpen(learn: false, block: false)
        case .sent, .pending:
            break
        }
    }

    // MARK: Diagnostics

    func diagnostics(_ done: @escaping (String) -> Void) {
        let main = status.mainFrame
        let screen = Geo.screen(containing: CGPoint(x: main.midX, y: main.midY)).map(Geo.cgFrame)
        scan(screen: screen) { [weak self] in
            guard let self else { return }
            var out = "LittleBox diagnostics \(Date())\n"
            out += "AX trusted: \(AXIsProcessTrusted())  screen capture: \(CGPreflightScreenCaptureAccess())  hover: \(Prefs.hoverOpen)\n"
            for s in NSScreen.screens {
                out += "screen \(s.localizedName) \(Geo.cgFrame(s)) bar=\(Geo.menuBarHeight(s)) notch=\(Geo.notch(of: s).map { "\($0)" } ?? "-")\n"
            }
            out += "box screen: \(screen.map { "\($0)" } ?? "nil")  box: \(main)  visible: \(self.status.isVisibleSomewhere)\n"
            out += "click-only items: \(Prefs.actionItems.sorted())\n\n"
            out += "order\tw\thidden\tcopies(id:w@y:on)\timage\tapp\ttitle\n"
            for i in self.items {
                let copies = i.copies.map { "\($0.id):\(Int($0.frame.width))@\(Int($0.frame.minY)):\($0.onScreen ? "on" : "off")" }
                    .joined(separator: ",")
                out += "\(Int(i.order))\t\(Int(i.frame.width))\t\(i.hidden)\t\(copies)\t"
                out += "\(self.images[i.id] != nil)\t\(i.appName)\t\(i.title)\n"
            }
            done(out)
        }
    }
}
