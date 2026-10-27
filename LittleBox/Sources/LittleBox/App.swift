import Cocoa

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { SelfTest.run(); return }
        if let i = args.firstIndex(of: "--preview-settings"), i + 1 < args.count {
            SelfTest.renderSettings(to: args[i + 1], dark: args.contains("--dark")); return
        }
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
            Preview.render(to: args[i + 1], dark: args.contains("--dark"), wide: args.contains("--wide"), args: args)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var status: StatusController!
    private var box: BoxController!
    private let settings = SettingsWindowController()
    private var lastDiagnose = Date.distantPast

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)

        Prefs.migrate()
        installMainMenu()
        status = StatusController()
        box = BoxController(status: status)
        box.onNeedsPermission = { [weak self] in self?.settings.show() }
        settings.onResetBoxPosition = { [weak self] in self?.status.resetPosition() }
        status.onRightClick = { [weak self] in self?.showMenu() }

        let d = UserDefaults.standard
        if !d.bool(forKey: "onboardedV2") || !AXIsProcessTrusted() {
            d.set(true, forKey: "onboardedV2")
            settings.show()
        }
        // If the system hid 📦 itself (e.g. behind the notch), the menu can't be reached:
        // show Settings so the app is never stranded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.status.isVisibleSomewhere else { return }
            self.settings.show()
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    /// Accessory apps have no visible menu bar, but key equivalents (⌘W, ⌘Q) still
    /// need a main menu while the Settings window is key.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: t("退出 LittleBox", "Quit LittleBox"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: t("关闭", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    private func showMenu() {
        box.close()
        let m = NSMenu()
        let s = NSMenuItem(title: t("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        s.target = self
        m.addItem(s)
        m.addItem(.separator())
        let q = NSMenuItem(title: t("退出 LittleBox", "Quit LittleBox"), action: #selector(quit), keyEquivalent: "q")
        q.target = self
        m.addItem(q)
        status.show(menu: m)
    }

    @objc private func openSettings() { DispatchQueue.main.async { self.settings.show() } }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: URL scheme (littlebox://open | settings | diagnose)

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let host = URL(string: s)?.host else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            switch host {
            case "open": box.open(anchor: status.mainFrame, byHover: false)
            case "settings": settings.show()
            case "diagnose":
                // Any app can open a URL; keep this cheap and rate-limited.
                guard Date().timeIntervalSince(lastDiagnose) > 2 else { return }
                lastDiagnose = Date()
                box.diagnostics { Self.write($0) }
            default: break
            }
        }
    }

    private static func write(_ text: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LittleBox")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("diagnostics.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
