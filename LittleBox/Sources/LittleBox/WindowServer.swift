import Cocoa

/// One menu bar item window as the window server sees it. On macOS 26 every
/// item's window is owned by Control Center and each display has its own copy;
/// items that collide with the notch (or with long app menus) are ordered out.
struct StatusWindow {
    let id: CGWindowID
    let frame: CGRect
    let onScreen: Bool
    let owner: pid_t
}

/// The status item windows sitting in one display's menu bar, left to right.
struct MenuBarRow {
    let screen: CGRect
    let windows: [StatusWindow]
}

/// An on-screen window that may belong to a menu or popover we opened.
struct UIWindow {
    let id: CGWindowID
    let frame: CGRect
    let layer: Int
    let owner: pid_t
    let name: String   // kCGWindowName, "" when missing (popovers and panels are untitled)
}

enum WindowServer {
    /// Window titles of other apps are only visible with Screen Recording; without it every
    /// title reads "", so "untitled" would say nothing. (A grant takes effect on relaunch.)
    private static let titlesReadable = CGPreflightScreenCaptureAccess()

    static let statusLayer = Int(CGWindowLevelForKey(.statusWindow))      // 25
    static let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow)) // 101
    private static let me = ProcessInfo.processInfo.processIdentifier

    static func statusWindows() -> [StatusWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == statusLayer,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b),
                  rect.height < 50, rect.width > 4 else { return nil }
            return StatusWindow(id: id, frame: rect, onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                                owner: w[kCGWindowOwnerPID as String] as? pid_t ?? 0)
        }
    }

    /// One row per display, keyed by screen (not by y, so displays sharing a top edge stay
    /// separate). When one process hosts nearly every item (Control Center on macOS 26),
    /// stray layer-25 windows from others are dropped so they can't shift positions.
    static func rows(_ windows: [StatusWindow]) -> [MenuBarRow] {
        NSScreen.screens.compactMap { s in
            let f = Geo.cgFrame(s)
            var row = windows
                .filter { abs($0.frame.minY - f.minY) < 1 && $0.frame.midX >= f.minX && $0.frame.midX < f.maxX }
                .sorted { $0.frame.minX < $1.frame.minX }
            // Only macOS 26+ hosts every app's item in one process; earlier systems give each
            // app its own windows, where this filter would wrongly drop third-party items.
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
                let counts = Dictionary(grouping: row, by: \.owner).mapValues(\.count)
                if counts.count > 1, let top = counts.max(by: { $0.value < $1.value }), top.value >= 4,
                   Double(top.value) >= 0.8 * Double(row.count) {
                    row = row.filter { $0.owner == top.key }
                }
            }
            return row.isEmpty ? nil : MenuBarRow(screen: f, windows: row)
        }
    }

    /// The AX rect is the icon as drawn, inset inside its (wider, taller) window slot,
    /// so match by containment of the icon's centre rather than by equal edges.
    static func match(_ frame: CGRect, in windows: [StatusWindow]) -> StatusWindow? {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return windows
            .filter { $0.frame.insetBy(dx: -1, dy: -1).contains(c) && $0.frame.width >= frame.width - 2 }
            .min { $0.frame.width < $1.frame.width }
    }

    /// Pairs each window of `home` with the same item in `other`. The order is not always
    /// identical across displays (neighbours get swapped, slots go missing), so this is a
    /// global alignment on widths read from the right (longest common subsequence); the
    /// leftovers are paired by equal width, nearest position first. Never by position alone.
    static func align(_ home: [StatusWindow], _ other: [StatusWindow]) -> [CGWindowID: StatusWindow] {
        let a = Array(home.reversed()), b = Array(other.reversed())
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [:] }
        func same(_ i: Int, _ j: Int) -> Bool { abs(a[i].frame.width - b[j].frame.width) <= 1 }
        var L = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                L[i][j] = same(i, j) ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
            }
        }
        var map = [CGWindowID: StatusWindow](), usedB = Set<Int>(), left: [Int] = []
        var i = 0, j = 0
        while i < n && j < m {
            if same(i, j) && L[i][j] == L[i + 1][j + 1] + 1 {
                map[a[i].id] = b[j]; usedB.insert(j); i += 1; j += 1
            } else if L[i + 1][j] >= L[i][j + 1] {
                left.append(i); i += 1
            } else {
                j += 1
            }
        }
        left += Array(i..<n)
        for x in left {
            let candidates = (0..<m).filter { !usedB.contains($0) && same(x, $0) }
            if let y = candidates.min(by: { abs($0 - x) < abs($1 - x) }) {
                map[a[x].id] = b[y]; usedB.insert(y)
            }
        }
        return map
    }

    /// The same item on every display.
    static func copies(of w: StatusWindow, in rows: [MenuBarRow]) -> [StatusWindow] {
        guard let home = rows.first(where: { $0.windows.contains { $0.id == w.id } }) else { return [w] }
        return rows.compactMap { r in r.screen == home.screen ? w : align(home.windows, r.windows)[w.id] }
    }

    /// Each display's menu bar (CG).
    private static func menuBars() -> [CGRect] {
        NSScreen.screens.map { s in
            let f = Geo.cgFrame(s)
            let h = max(s.frame.maxY - s.visibleFrame.maxY, s.safeAreaInsets.top, 24)
            return CGRect(x: f.minX, y: f.minY, width: f.width, height: h)
        }
    }

    private static func screenFrame(of r: CGRect) -> CGRect? {
        NSScreen.screens.map(Geo.cgFrame).first { $0.contains(CGPoint(x: r.midX, y: r.minY + 1)) }
    }

    /// Large in both dimensions, like a maximized document window.
    static func isHuge(_ r: CGRect) -> Bool {
        guard let s = screenFrame(of: r) else { return false }
        return r.width >= 0.6 * s.width && r.height >= 0.6 * s.height
    }

    /// Top edge sits in or just below a menu bar, like a dropped-down menu or popover.
    static func hangsFromBar(_ r: CGRect) -> Bool {
        menuBars().contains { bar in
            r.minY >= bar.minY - 2 && r.minY <= bar.maxY + 40 && r.midX >= bar.minX && r.midX <= bar.maxX
        }
    }

    static func popoverSized(_ r: CGRect) -> Bool {
        guard let s = screenFrame(of: r) else { return false }
        return r.height < 0.7 * s.height && r.width < 0.5 * s.width
    }

    /// A menu (pop-up level), a popover (status level and up), or a small panel of the
    /// item's app: one hanging from the menu bar, or an untitled one (popovers such as Box
    /// Drive's web view are untitled; document windows have titles). For an Apple system
    /// item (`system`), any non-huge window of its process counts: Control Center modules
    /// are always panels. A regular app window is not menu-like: an item that opens one
    /// performed an action.
    static func isMenuLike(_ w: UIWindow, pid: pid_t, system: Bool = false) -> Bool {
        if w.layer >= statusLayer || w.layer == popUpMenuLayer { return true }
        guard w.owner == pid, !isHuge(w.frame) else { return false }
        if system { return true }
        return popoverSized(w.frame) && (hangsFromBar(w.frame) || (w.name.isEmpty && titlesReadable))
    }

    /// Smaller than 40x40 in both dimensions, or centred on no display: transient
    /// placeholders (a popover's first window can appear at a junk position) rather than UI.
    static func isTinyOrOffscreen(_ r: CGRect) -> Bool {
        (r.width < 40 && r.height < 40) || !Geo.isOnAnyScreen(r)
    }

    /// IDs of every on-screen window, as the "before" picture for a press.
    static func onScreenIDs() -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    /// On-screen windows that could be UI opened from an item of `pid`: its own windows
    /// and any pop-up menu. Menu bar slots, the menu bar itself and maximized windows are
    /// excluded. Callers diff this against a snapshot taken before the press.
    static func openUI(pid: pid_t) -> [UIWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let bars = menuBars()
        let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        return info.compactMap { w in
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let owner = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard owner != me, layer != mainMenuLayer, owner == pid || layer == popUpMenuLayer,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b),
                  rect.width > 20, rect.height > 20 else { return nil }
            if layer == statusLayer && rect.height < 50 && bars.contains(where: { abs($0.minY - rect.minY) < 2 }) {
                return nil
            }
            if isTinyOrOffscreen(rect) { return nil }
            if layer != popUpMenuLayer && isHuge(rect) { return nil }
            return UIWindow(id: id, frame: rect, layer: layer, owner: owner,
                            name: w[kCGWindowName as String] as? String ?? "")
        }
    }

    /// A copy of the item that is on screen right now, re-read from the window server.
    static func visibleCopy(_ ids: [CGWindowID]) -> CGRect? {
        for id in ids {
            guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
                  (info[kCGWindowLayer as String] as? Int) == statusLayer,
                  (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            return r
        }
        return nil
    }
}
