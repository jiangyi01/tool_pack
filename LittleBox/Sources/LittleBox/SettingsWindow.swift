import Cocoa
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsState: ObservableObject {
    @Published var ax = AXIsProcessTrusted()
    @Published var capture = CGPreflightScreenCaptureAccess()
    @Published var hover = Prefs.hoverOpen { didSet { Prefs.hoverOpen = hover } }
    @Published var login = false
    @Published var loginNote: String?
    @Published var captureRequested = false
    @Published var axRequested = false
    @Published var clickOnlyCount = Prefs.actionItems.count
    @Published var relaunchError: String?
    private var relaunching = false
    var onResetBoxPosition: (() -> Void)?

    init() { refresh() }

    func refresh() {
        ax = AXIsProcessTrusted()
        capture = CGPreflightScreenCaptureAccess()
        clickOnlyCount = Prefs.actionItems.count
        let st = SMAppService.mainApp.status
        login = st == .enabled || st == .requiresApproval
        if st == .requiresApproval {
            loginNote = t("请在「系统设置 › 通用 › 登录项」里允许 LittleBox", "Allow LittleBox in System Settings › General › Login Items")
        } else if st == .enabled {
            loginNote = nil
        }
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginNote = nil
        } catch {
            loginNote = error.localizedDescription
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refresh()
    }

    /// After an update macOS may keep a stale entry that no longer matches this copy of
    /// the app; switching it on then does nothing. Clearing our own entry first lets the
    /// prompt add a fresh one.
    private func resetEntry(_ service: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.yijiang.littlebox"]
        try? p.run()
        p.waitUntilExit()
    }

    func grantAX() {
        axRequested = true
        if !AXIsProcessTrusted() { resetEntry("Accessibility") }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { openPane("Privacy_Accessibility") }
    }

    /// No reset here: Screen Recording only reads as granted after a relaunch, so a reset
    /// could wipe a grant the user just made. build_app.sh clears stale entries instead.
    func grantCapture() {
        if captureRequested { openPane("Privacy_ScreenCapture"); return }
        captureRequested = true
        if !CGRequestScreenCaptureAccess() { openPane("Privacy_ScreenCapture") }
    }

    func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    func resetClickOnly() {
        Prefs.actionItems = []
        refresh()
    }

    /// Screen Recording only takes effect in a fresh process. Start the new copy through
    /// LaunchServices (so it gets its own job), and quit only once it is running.
    func relaunch() {
        guard !relaunching else { return }
        relaunching = true
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { [weak self] _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        self?.relaunching = false
                        self?.relaunchError = error.localizedDescription
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    private func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.large)
            } else {
                Button(t("开启…", "Enable…"), action: action)
            }
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Label on the left, switch on the right, like System Settings.
private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden()
        }
    }
}

private struct Hint: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action).controlSize(.small)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: SettingsState
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LittleBox").font(.title2.weight(.semibold))
                    Text(t("被刘海挡住的菜单栏图标都收在 📦 里。鼠标移到 📦 上就能看到并使用它们；右键 📦 回到这里。",
                           "Menu bar icons hidden by the notch live in 📦. Point at 📦 to use them; right-click 📦 to come back here."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card(title: t("权限", "Permissions")) {
                PermissionRow(title: t("辅助功能", "Accessibility"),
                              detail: t("必需 · 读取并打开菜单栏图标", "Required · find and open menu bar icons"),
                              granted: state.ax, action: state.grantAX)
                if state.axRequested && !state.ax {
                    Hint(text: t("已在系统设置里打开，这里却仍未生效？用 − 删掉列表里的 LittleBox，再把它拖回列表。",
                                 "Switched on but still not working? Remove LittleBox from the list with −, then drag it back in."),
                         button: t("在访达中显示", "Show in Finder"), action: state.revealApp)
                }
                Divider()
                PermissionRow(title: t("屏幕录制", "Screen Recording"),
                              detail: t("推荐 · 盒子里的图标和菜单栏上一模一样", "Recommended · show icons exactly as they look"),
                              granted: state.capture, action: state.grantCapture)
                if state.captureRequested && !state.capture {
                    Hint(text: t("在系统设置里打开 LittleBox 后，需重新启动才生效。若已打开仍无效，用 − 删掉再拖回列表。",
                                 "Once enabled in System Settings, restart LittleBox. Still off? Remove it with − and drag it back."),
                         button: t("重新启动", "Restart"), action: state.relaunch)
                    if let e = state.relaunchError { Text(e).font(.caption).foregroundStyle(.red) }
                }
            }

            Card(title: t("使用", "Behavior")) {
                SwitchRow(title: t("鼠标悬停即可打开，无需点击", "Open on hover, no click needed"), isOn: $state.hover)
                if state.clickOnlyCount > 0 {
                    Hint(text: t("\(state.clickOnlyCount) 个图标点击时执行动作，悬停不会触发它们", "\(state.clickOnlyCount) icons run an action when clicked, so hover skips them"),
                         button: t("重置", "Reset"), action: state.resetClickOnly)
                }
                Divider()
                SwitchRow(title: t("开机自动启动", "Launch at login"),
                          isOn: Binding(get: { state.login }, set: { state.setLogin($0) }))
                if let note = state.loginNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(t("退出 LittleBox", "Quit LittleBox")) { NSApp.terminate(nil) }
                Button(t("找不到 📦？", "Can't find 📦?")) { state.onResetBoxPosition?() }
                    .help(t("把 📦 放回菜单栏最右侧", "Put 📦 back at the far right of the menu bar"))
                Spacer()
                Button(t("完成", "Done"), action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .toggleStyle(.switch)
        .padding(22)
        .frame(width: 460)
        .onExitCommand(perform: onDone)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let state = SettingsState()
    private var window: NSWindow?
    private var timer: Timer?
    private var previousApp: NSRunningApplication?

    var onResetBoxPosition: (() -> Void)? {
        get { state.onResetBoxPosition }
        set { state.onResetBoxPosition = newValue }
    }

    func show() {
        if window == nil {
            let host = NSHostingView(rootView: SettingsView(state: state, onDone: { [weak self] in self?.window?.close() }))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.contentView = host
            w.delegate = self
            w.center()
            window = w
        }
        state.refresh()
        // Permissions are granted in System Settings; reflect them live.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.refresh() }
        }
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid() { previousApp = f }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Give focus back, so ⌘Q and typing go to the app the user was in, not to LittleBox.
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        let prev = previousApp
        previousApp = nil
        DispatchQueue.main.async {
            guard NSApp.isActive else { return }
            if let prev, !prev.isTerminated { prev.activate(options: []) } else { NSApp.hide(nil) }
        }
    }
}
