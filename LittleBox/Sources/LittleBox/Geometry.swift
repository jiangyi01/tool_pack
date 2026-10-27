import Cocoa

/// Coordinate helpers. AX and CGWindow use global top-left coordinates
/// (y grows downward from the top of the primary display); AppKit uses bottom-left.
enum Geo {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func toCG(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func toCG(point p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    static func cgFrame(_ s: NSScreen) -> CGRect { toCG(s.frame) }

    static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { cgFrame($0).insetBy(dx: 0, dy: -1).contains(p) }
    }

    /// The camera housing of a notched display, in CG coordinates.
    static func notch(of s: NSScreen) -> CGRect? {
        guard s.safeAreaInsets.top > 0,
              let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return nil }
        let f = s.frame
        return toCG(NSRect(x: f.minX + l.width, y: f.maxY - s.safeAreaInsets.top,
                           width: f.width - l.width - r.width, height: s.safeAreaInsets.top))
    }

    static func isOnAnyScreen(_ r: CGRect) -> Bool {
        screen(containing: CGPoint(x: r.midX, y: r.midY)) != nil
    }

    /// Height reserved at the top of `s` for the menu bar (0 when it auto-hides).
    static func menuBarHeight(_ s: NSScreen) -> CGFloat { s.frame.maxY - s.visibleFrame.maxY }

    /// Mouse is in the menu bar strip of the screen it is on.
    static var mouseInMenuBar: Bool {
        let p = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: {
            p.x >= $0.frame.minX && p.x < $0.frame.maxX && p.y > $0.frame.minY && p.y <= $0.frame.maxY
        }) else { return false }
        let bar = max(menuBarHeight(s), s.safeAreaInsets.top, NSStatusBar.system.thickness)
        return p.y >= s.frame.maxY - bar - 4
    }
}
