import Cocoa

enum AX {
    static func raw(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        (raw(el, attr) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (raw(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = raw(el, kAXPositionAttribute), let s = raw(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}

/// A status item ("menu bar extra") belonging to some app.
struct BarItem: Identifiable {
    let id: String           // "pid-index": unique while the app runs
    let pid: pid_t
    let element: AXUIElement
    let appName: String
    let appKey: String       // bundle id, or executable path for apps without one
    let appIcon: NSImage?
    let title: String        // text the item shows, e.g. "971"; often empty
    let identifier: String   // e.g. com.apple.menuextra.battery
    let indexInApp: Int
    let appItemCount: Int
    var frame: CGRect
    var copies: [StatusWindow] = []   // this item's window on every display
    var hidden = false                // not visible on the display the box serves
    var order: CGFloat = 0            // left-to-right position on that display
    var reused = false                // carried over from the last scan (app was busy)

    /// Survives relaunches and changing titles (a counter like "971" must not change it).
    /// AXIdentifier is used only when it looks like a real identifier: OneDrive puts a
    /// description there with a newline and a changing sync status.
    var stableKey: String {
        let realID = !identifier.isEmpty && identifier.count <= 60
            && identifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        return "\(appKey)|\(realID ? identifier : "\(indexInApp)/\(appItemCount)")"
    }
    var isSystem: Bool { appKey.hasPrefix("com.apple.") }
    /// Control Center and SystemUIServer items always show a menu or panel. Other Apple
    /// items can be plain actions (e.g. the screen-recording stop button).
    var isMenuHost: Bool { appKey == "com.apple.controlcenter" || appKey == "com.apple.systemuiserver" }
}

struct AppInfo {
    let pid: pid_t
    let name: String
    let key: String
    let icon: NSImage?

    @MainActor static func running() -> [AppInfo] {
        NSWorkspace.shared.runningApplications.map {
            AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "?",
                    key: $0.bundleIdentifier ?? $0.executableURL?.path ?? $0.localizedName ?? "?", icon: $0.icon)
        }
    }
}

enum Scanner {
    /// Reads every app's AXExtrasMenuBar and works out which items are hidden on the
    /// display whose frame is `screen` (CG). Apps that are too busy to answer keep the
    /// items from `previous`. Call off the main thread.
    static func snapshot(apps: [AppInfo], screen: CGRect?, notch: CGRect?, previous: [BarItem]) -> [BarItem] {
        let me = ProcessInfo.processInfo.processIdentifier
        let lock = NSLock()
        var found: [BarItem] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let app = apps[i]
            guard app.pid > 0, app.pid != me else { return }
            let axApp = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.3)
            var v: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &v)
            func reuse() {
                let old = previous.filter { $0.pid == app.pid }.map { var o = $0; o.reused = true; return o }
                lock.lock(); found += old; lock.unlock()
            }
            if err == .cannotComplete { reuse(); return }
            guard err == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return }
            let bar = v as! AXUIElement
            var kv: CFTypeRef?
            let kerr = AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kv)
            if kerr == .cannotComplete { reuse(); return }
            let kids = (kv as? [AXUIElement]) ?? []
            var local: [BarItem] = []
            for (idx, el) in kids.enumerated() {
                guard let f = AX.frame(el), f.width > 0 else { continue }
                local.append(BarItem(id: "\(app.pid)-\(idx)", pid: app.pid, element: el, appName: app.name,
                                     appKey: app.key, appIcon: app.icon,
                                     title: AX.string(el, kAXTitleAttribute) ?? "",
                                     identifier: AX.string(el, kAXIdentifierAttribute) ?? "",
                                     indexInApp: idx, appItemCount: kids.count, frame: f))
            }
            lock.lock(); found += local; lock.unlock()
        }

        let windows = WindowServer.statusWindows()
        let rows = WindowServer.rows(windows)
        let servedRow = rows.first { $0.screen == screen }
        for i in found.indices where !found[i].reused {   // a busy app's old frame could match a neighbour
            let w = WindowServer.match(found[i].frame, in: windows)
            found[i].copies = w.map { WindowServer.copies(of: $0, in: rows) } ?? []
            let served = screen.flatMap { s in
                found[i].copies.first { s.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            }
            if let copy = served {
                // Hidden here: ordered out by the system (macOS 26), or really overlapping the notch.
                let notchHit = notch.map { n in min(n.maxX, copy.frame.maxX) - max(n.minX, copy.frame.minX) > 0.5 } ?? false
                found[i].hidden = !copy.onScreen || notchHit
                found[i].order = copy.frame.minX
            } else if servedRow != nil {
                // The display has a menu bar but no copy of this item: it isn't shown there.
                found[i].hidden = true
                found[i].order = found[i].frame.minX
            } else {
                found[i].hidden = !(w?.onScreen ?? Geo.isOnAnyScreen(found[i].frame))
                found[i].order = found[i].frame.minX
            }
        }
        return found.sorted { $0.order < $1.order }
    }
}
