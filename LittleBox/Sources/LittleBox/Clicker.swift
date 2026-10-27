import Cocoa

/// What happened when we asked an item to open.
enum PressResult {
    case sent      // the app accepted the action
    case pending   // timed out — usually the app is running its menu loop
    case failed    // the item doesn't support the action, or is gone
    case busy      // the app didn't answer a cheap probe; nothing was sent
}

/// Everything needed to close what an open press showed. `windows` is what the press
/// was seen to show; the controller fills it in as menus/popovers appear.
struct OpenRecord {
    let gen: Int
    let element: AXUIElement
    let pid: pid_t
    let button: Clicker.Button
    let baseline: Set<CGWindowID>
    let pressedAt: Date
    var windows: Set<CGWindowID> = []
}

/// Opens and closes real menu bar items. Accessibility actions are preferred because
/// they reach items the notch hides and never move the cursor. Call off the main
/// thread, one at a time (a serial queue): AX calls block while the target app works.
enum Clicker {
    enum Button { case left, right, option }

    static let timeout: Float = 0.25

    /// A cheap read, to avoid queueing a press in an app that is hung right now.
    static func isBusy(_ el: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(el, 0.1)
        var v: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        AXUIElementSetMessagingTimeout(el, timeout)
        return r == .cannotComplete
    }

    private static func perform(_ el: AXUIElement, _ action: String) -> PressResult {
        AXUIElementSetMessagingTimeout(el, timeout)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = AXUIElementPerformAction(el, action as CFString)
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        switch r {
        case .success: return .sent
        case .cannotComplete where dt >= Double(timeout) * 0.9: return .pending
        default: return .failed
        }
    }

    private static func menus(of el: AXUIElement, pid: pid_t) -> [AXUIElement] {
        (AX.children(el) + AX.children(AXUIElementCreateApplication(pid)))
            .filter { AX.string($0, kAXRoleAttribute) == kAXMenuRole }
    }

    static func open(_ el: AXUIElement, pid: pid_t, button: Button) -> PressResult {
        switch button {
        case .left, .option:
            return perform(el, kAXPressAction)
        case .right:
            let r = perform(el, "AXShowMenu")
            if r != .failed { return r }
            // A plain left press is only a faithful substitute when the item simply has a menu;
            // otherwise it would fire the item's left-click action.
            if AX.children(el).contains(where: { AX.string($0, kAXRoleAttribute) == kAXMenuRole }) {
                return perform(el, kAXPressAction)
            }
            return .failed
        }
    }

    /// Closes what `rec`'s press opened. Menus get AXCancel. A popover is pressed again
    /// (most toggle) — but only while a window that this press showed is still up, and
    /// never for a right-click or ⌥-click open, so an action can't fire twice.
    static func dismiss(_ rec: OpenRecord) {
        var cancelled = false
        for m in menus(of: rec.element, pid: rec.pid) {
            let r = AXUIElementPerformAction(m, kAXCancelAction as CFString)
            if r == .success || r == .cannotComplete { cancelled = true }
        }
        if cancelled { return }
        guard rec.button == .left else { return }
        let now = WindowServer.openUI(pid: rec.pid)
        var target = rec.windows.filter { id in now.contains { $0.id == id } }
        if target.isEmpty, rec.windows.isEmpty, Date().timeIntervalSince(rec.pressedAt) < 10 {
            // A slow popover (e.g. a web view) that appeared after we stopped watching:
            // only the item's own app, only menu-like, only new since the press.
            target = Set(now.filter { $0.owner == rec.pid && !rec.baseline.contains($0.id)
                && WindowServer.isMenuLike($0, pid: rec.pid) }.map(\.id))
        }
        guard !target.isEmpty else { return }
        usleep(120_000)   // a popover that is already fading out must not be toggled back on
        let still = Set(WindowServer.openUI(pid: rec.pid).map(\.id))
        if !target.isDisjoint(with: still) {
            _ = perform(rec.element, kAXPressAction)
        }
    }

    /// Electron trays draw their own view: AXPress "succeeds" without doing anything.
    static func isElectron(_ pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(
            "Contents/Frameworks/Electron Framework.framework").path)
    }

    /// Posts a real mouse click on a visible status item slot, then puts the cursor back.
    /// Only used for ⌥-click and for items that ignore Accessibility actions.
    static func click(_ slot: CGRect, button: Button) {
        // Never synthesize a click while the user is still holding a button.
        var waited = 0
        while CGEventSource.buttonState(.combinedSessionState, button: .left) && waited < 50 {
            usleep(20_000); waited += 1
        }
        let point = CGPoint(x: slot.midX, y: slot.midY)
        let src = CGEventSource(stateID: .hidSystemState)
        let saved = CGEvent(source: nil)?.location
        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) =
            button == .right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        guard let down = CGEvent(mouseEventSource: src, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
              let up = CGEvent(mouseEventSource: src, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton)
        else { return }
        if button == .option { down.flags = .maskAlternate; up.flags = .maskAlternate }
        down.post(tap: .cghidEventTap)
        usleep(25_000)
        up.post(tap: .cghidEventTap)
        if let saved {
            usleep(40_000)
            CGWarpMouseCursorPosition(saved)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}
