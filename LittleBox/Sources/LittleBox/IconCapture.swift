import Cocoa

/// Captures the real picture of a menu bar item (needs Screen Recording permission).
/// CGWindowListCreateImage is unavailable in the macOS 15+ SDK but still ships in
/// CoreGraphics, and unlike ScreenCaptureKit it can capture windows that are off screen.
enum IconCapture {
    private typealias CreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let createImage: CreateImageFn? = {
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CreateImageFn.self)
    }()

    static var isAvailable: Bool { createImage != nil }

    static func image(of windowID: CGWindowID) -> CGImage? {
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return createImage?(.null, CGWindowListOption.optionIncludingWindow.rawValue, windowID, options.rawValue)?
            .takeRetainedValue()
    }

    /// Whether anything is drawn, and the brightness of its grey (template-style) pixels.
    /// Coloured pixels don't vote, so a colourful app icon can't flip the strip's appearance.
    static func analyze(_ img: CGImage) -> (visible: Bool, luminance: CGFloat?) {
        let w = 32, h = 32
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (false, nil) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var drawn = 0, grey = 0
        var sum: CGFloat = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 60 {
            drawn += 1
            guard px[i + 3] >= 160 else { continue }
            let a = CGFloat(px[i + 3])
            let r = CGFloat(px[i]) / a, g = CGFloat(px[i + 1]) / a, b = CGFloat(px[i + 2]) / a
            guard max(r, g, b) - min(r, g, b) <= 0.15 else { continue }
            sum += 0.299 * r + 0.587 * g + 0.114 * b
            grey += 1
        }
        return (drawn >= 4, grey >= 4 ? sum / CGFloat(grey) : nil)
    }

    /// Prefers the sharpest copy that is on screen (a 2× display beats a 1× one), and
    /// only falls back to off-screen copies when no visible one can be captured.
    static func capture(_ item: BarItem) -> (NSImage, CGFloat?)? {
        var best: (img: CGImage, frame: CGRect, lum: CGFloat?, density: CGFloat)?
        for c in item.copies where c.onScreen {
            guard let img = image(of: c.id) else { continue }
            let a = analyze(img)
            guard a.visible else { continue }
            let density = CGFloat(img.width) / max(c.frame.width, 1)
            if best == nil || density > best!.density { best = (img, c.frame, a.luminance, density) }
            if density >= 2 { break }
        }
        if best == nil {
            for c in item.copies where !c.onScreen {
                guard let img = image(of: c.id) else { continue }
                let a = analyze(img)
                if a.visible { best = (img, c.frame, a.luminance, 1); break }
            }
        }
        guard let best else { return nil }
        return (NSImage(cgImage: best.img, size: best.frame.size), best.lum)
    }
}
