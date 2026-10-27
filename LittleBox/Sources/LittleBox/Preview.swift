import Cocoa
import SwiftUI

/// `LittleBox --preview out.png [--dark] [--wide]` renders the strip offscreen with sample
/// items, to check the layout without any permissions. Development aid only.
@MainActor
enum Preview {
    static func render(to path: String, dark: Bool, wide: Bool, args: [String] = []) {
        _ = NSApplication.shared
        let running = NSWorkspace.shared.runningApplications
        func app(_ name: String) -> NSRunningApplication? { running.first { $0.localizedName == name } }

        var samples: [(String, String, Int)] = [   // app name, title, item count for that app
            ("Microsoft Outlook", "", 1), ("OneDrive", "", 2), ("OneDrive", "", 2), ("Scholar Bar", "971", 1),
            ("Remote Support", "", 1), ("Claude", "", 1), ("PaperDeck", "2", 1), ("Claude Usage Bar", "A 61 · B 68", 1),
        ]
        if wide { samples += samples.map { ($0.0, $0.1, $0.2) } + samples.prefix(4) }

        let items: [BarItem] = samples.enumerated().map { i, s in
            let a = app(s.0)
            return BarItem(id: "p\(i)", pid: a?.processIdentifier ?? 0,
                           element: AXUIElementCreateApplication(a?.processIdentifier ?? 0),
                           appName: s.0, appKey: a?.bundleIdentifier ?? s.0,
                           appIcon: a?.icon ?? NSImage(named: NSImage.applicationIconName),
                           title: s.1, identifier: "", indexInApp: i, appItemCount: s.2, frame: .zero)
        }

        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let view = StripView()
        view.appearance = appearance
        let footer = args.contains("--footer") ? t("「Box」被挡住时无法直接打开 · 可按住 ⌘ 把它拖到菜单栏右侧", "Box can't be opened while hidden · ⌘-drag it further right in the menu bar") : nil
        let size = view.setContent(items: items, images: [:], message: nil, footer: footer, maxWidth: 760)
        view.frame = NSRect(origin: .zero, size: size)
        view.hoverIndex = 3

        let margin: CGFloat = 12
        let canvas = NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            (dark ? NSColor(white: 0.35, alpha: 1) : NSColor(white: 0.75, alpha: 1)).setFill()  // "desktop"
            NSRect(origin: .zero, size: canvas).fill()
            let panel = NSRect(x: margin, y: margin, width: size.width, height: size.height)
            (dark ? NSColor(white: 0.17, alpha: 0.96) : NSColor(white: 0.96, alpha: 0.96)).setFill()
            NSBezierPath(roundedRect: panel, xRadius: 10, yRadius: 10).fill()
            NSColor.white.withAlphaComponent(dark ? 0.12 : 0.35).setStroke()
            NSBezierPath(roundedRect: panel.insetBy(dx: 0.25, dy: 0.25), xRadius: 10, yRadius: 10).stroke()
            // StripView is flipped; give it a flipped context, as AppKit would.
            let cg = NSGraphicsContext.current!.cgContext
            cg.saveGState()
            cg.translateBy(x: margin, y: margin + size.height)
            cg.scaleBy(x: 1, y: -1)
            let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = flipped
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(Int(size.width))x\(Int(size.height))")
    }
}

/// `LittleBox --selftest`: checks the pieces that can be checked without permissions.
@MainActor
enum SelfTest {
    static func run() {
        _ = NSApplication.shared
        func row(_ widths: [CGFloat], base: UInt32) -> [StatusWindow] {
            var x: CGFloat = 0
            return widths.enumerated().map { i, w in
                defer { x += w }
                return StatusWindow(id: base + UInt32(i), frame: CGRect(x: x, y: 0, width: w, height: 30), onScreen: true, owner: 1)
            }
        }
        func check(_ name: String, _ home: [CGFloat], _ other: [CGFloat], expect: [Int?]) {
            let h = row(home, base: 100), o = row(other, base: 200)
            let m = WindowServer.align(h, o)
            let got: [Int?] = h.map { w in m[w.id].map { Int($0.id) - 200 } }
            print(got == expect ? "PASS" : "FAIL", name, "got", got.map { $0.map(String.init) ?? "-" }, "expect", expect.map { $0.map(String.init) ?? "-" })
        }
        // Observed: built-in has …40,45,49,83… while the externals have …40,49,45,83…
        check("swap", [38, 40, 45, 49, 83, 42, 152], [38, 40, 49, 45, 83, 42, 152], expect: [0, 1, 3, 2, 4, 5, 6])
        // A slot missing on the other display must not shift everything left of it.
        check("deletion", [38, 40, 45, 49, 83], [38, 40, 49, 83], expect: [0, 1, nil, 2, 3])
        // Control Center re-packed one item further away.
        check("displacement", [38, 45, 40, 49, 83, 42], [38, 40, 49, 83, 45, 42], expect: [0, 4, 1, 2, 3, 5])
        check("identical", [38, 40, 45], [38, 40, 45], expect: [0, 1, 2])

        // Live: align every display's row with the first one and show the width pairs.
        let rows = WindowServer.rows(WindowServer.statusWindows())
        print("live rows:", rows.map { "\(Int($0.screen.minX)),\(Int($0.screen.minY)) n=\($0.windows.count)" })
        if let home = rows.first {
            for r in rows.dropFirst() {
                let m = WindowServer.align(home.windows, r.windows)
                let bad = home.windows.filter { w in m[w.id].map { abs($0.frame.width - w.frame.width) > 1 } ?? false }
                let unmatched = home.windows.filter { m[$0.id] == nil }
                print("  row \(Int(r.screen.minX)),\(Int(r.screen.minY)): paired \(m.count)/\(home.windows.count), width mismatches \(bad.count), unmatched widths \(unmatched.map { Int($0.frame.width) })")
            }
            let hidden = home.windows.filter { !$0.onScreen }.map { Int($0.frame.width) }
            print("  first row hidden widths:", hidden)
        }

        // Settings must have a real size.
        let host = NSHostingView(rootView: SettingsView(state: SettingsState(), onDone: {}))
        let size = host.fittingSize
        print(size.width > 300 && size.height > 300 ? "PASS" : "FAIL", "settings fitting size", size)
    }

    static func renderSettings(to path: String, dark: Bool) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SettingsView(state: SettingsState(), onDone: {}))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(Int(size.width))x\(Int(size.height))")
    }
}
