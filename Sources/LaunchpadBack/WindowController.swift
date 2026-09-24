import AppKit
import CoreImage
import ImageIO
import SwiftUI

final class LaunchpadWindow: NSWindow {
    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                  styleMask: [.borderless],
                  backing: .buffered,
                  defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Just below the Dock: like Launchpad, the Dock stays visible on top.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class WindowController {
    let window: LaunchpadWindow
    let model: LaunchpadModel
    private(set) var isVisible = false
    private var hideTask: Task<Void, Never>?

    init(model: LaunchpadModel) {
        self.model = model
        window = LaunchpadWindow()
        let host = NSHostingView(rootView: LaunchpadRootView(model: model))
        // Cover the notch / menu-bar strip too; otherwise the desktop peeks through at the top.
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        window.contentView = host
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        hideTask?.cancel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]

        window.setFrame(screen.frame, display: false)
        let dock = max(0, screen.visibleFrame.minY - screen.frame.minY)
        model.dockInset = max(dock, 16)
        model.wallpaper = Wallpaper.blurred(for: screen)
        model.viewSize = screen.frame.size

        if !isVisible { model.prepareForShow() }
        isVisible = true
        model.shown = false

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        applyPresentation()

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self, self.isVisible else { return }
            withAnimation(.easeOut(duration: 0.24)) { self.model.shown = true }
        }
    }

    /// Launchpad takes over the whole screen: Dock and menu bar slide away while it's open.
    func applyPresentation() {
        guard isVisible else { return }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    /// - Parameter launching: an app is being launched (or we already lost focus), so don't hide the app.
    func hide(launching: Bool = false) {
        guard isVisible else { return }
        isVisible = false
        withAnimation(.easeInOut(duration: 0.22)) { model.shown = false }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 235_000_000)
            guard let self, !Task.isCancelled else { return }
            self.window.orderOut(nil)
            NSApp.presentationOptions = []
            self.model.didHide()
            if !launching, NSApp.isActive { NSApp.hide(nil) }
        }
    }
}

// MARK: - Blurred wallpaper (what Launchpad shows behind the icons)

@MainActor
enum Wallpaper {
    private static var cache: [String: NSImage] = [:]

    static func blurred(for screen: NSScreen) -> NSImage? {
        guard let url0 = NSWorkspace.shared.desktopImageURL(for: screen), let url = resolveImageURL(url0) else { return nil }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Dynamic wallpapers (dawn → night) hold several frames: pick the one for right now.
        let frame = DynamicWallpaper.currentFrameIndex(source)
        let key = "v2|\(url.path)|\(mod)|\(frame)|\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        if let img = cache[key] { return img }

        guard let cg = CGImageSourceCreateImageAtIndex(source, frame, nil) else { return nil }

        let target = CGSize(width: max(64, screen.frame.width / 3), height: max(64, screen.frame.height / 3))
        let raw = CIImage(cgImage: cg)
        guard raw.extent.width > 0, raw.extent.height > 0 else { return nil }
        let average = raw.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: raw.extent)])
            .settingAlphaOne(in: CGRect(x: 0, y: 0, width: 1, height: 1))
            .clampedToExtent()
            .cropped(to: raw.extent)
        let input = raw.composited(over: average)
        let scale = max(target.width / input.extent.width, target.height / input.extent.height)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(x: scaled.extent.midX - target.width / 2,
                          y: scaled.extent.midY - target.height / 2,
                          width: target.width, height: target.height)
        let blurred = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: 28)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.2,
                kCIInputBrightnessKey: -0.05,
            ])
            .cropped(to: crop)
        let ctx = CIContext()
        guard let out = ctx.createCGImage(blurred, from: crop) else { return nil }
        let img = NSImage(cgImage: out, size: target)
        cache = [key: img]
        return img
    }

    /// macOS 26+ wallpapers are often `.madesktop` packages / dynamic sets rather than a plain image file.
    /// Find a real, loadable image for them (inside the package, or in the hidden .wallpapers/.thumbnails dirs).
    private static func hasAlpha(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
    }

    private static func resolveImageURL(_ url: URL) -> URL? {
        let fm = FileManager.default
        let imageExts: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff"]
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists, !isDir.boolValue, imageExts.contains(url.pathExtension.lowercased()), NSImage(contentsOf: url)?.isValid == true {
            return url
        }
        var candidates: [URL] = []
        func collect(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return }
            for it in items {
                let v = try? it.resourceValues(forKeys: [.isDirectoryKey])
                if v?.isDirectory == true {
                    if depth > 0 { collect(it, depth: depth - 1) }
                } else if imageExts.contains(it.pathExtension.lowercased()) {
                    candidates.append(it)
                }
            }
        }
        if exists && isDir.boolValue { collect(url, depth: 3) }
        let base = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        for hidden in [".wallpapers", ".thumbnails"] {
            let d = parent.appendingPathComponent(hidden)
            let sub = d.appendingPathComponent(base)
            if fm.fileExists(atPath: sub.path) { collect(sub, depth: 2) }
            if let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) {
                candidates += items.filter { $0.deletingPathExtension().lastPathComponent == base && imageExts.contains($0.pathExtension.lowercased()) }
            }
        }
        // Largest file first = full-resolution image rather than a thumbnail.
        let sorted = candidates.sorted {
            ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let loadable = sorted.filter { NSImage(contentsOf: $0)?.isValid == true }
        return loadable.first { !hasAlpha($0) } ?? loadable.first
    }
}


// MARK: - Dynamic wallpaper (time of day / light–dark)

/// Apple dynamic HEICs carry an `apple_desktop` XMP tag: `h24` (time-based), `solar` (sun position)
/// or `apr` (light/dark). Each is a base64 binary plist mapping frames to times / sun positions.
@MainActor
enum DynamicWallpaper {
    static func currentFrameIndex(_ source: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 1, let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return 0 }
        let tags = (CGImageMetadataCopyTags(meta) as? [AnyObject]) ?? []
        var info: [String: [String: Any]] = [:]
        for obj in tags {
            let tag = obj as! CGImageMetadataTag
            guard let name = CGImageMetadataTagCopyName(tag) as String?,
                  ["h24", "solar", "apr"].contains(name),
                  let value = CGImageMetadataTagCopyValue(tag) as? String,
                  let data = Data(base64Encoded: value),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            info[name] = plist
        }
        let idx: Int? = {
            if let h24 = info["h24"] { return timeBased(h24) }
            if let solar = info["solar"] { return solarBased(solar) }
            if let apr = info["apr"] { return appearanceBased(apr) }
            return nil
        }()
        guard let i = idx, i >= 0, i < count else { return 0 }
        return i
    }

    private static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func appearanceBased(_ d: [String: Any]) -> Int? {
        (isDark ? d["d"] : d["l"]) as? Int
    }

    /// h24: {"ti": [{"i": frame, "t": fraction of day}], "ap": {"l","d"}}
    private static func timeBased(_ d: [String: Any]) -> Int? {
        guard let ti = d["ti"] as? [[String: Any]], !ti.isEmpty else { return appearanceFallback(d) }
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let now = (Double(c.hour ?? 0) * 3600 + Double(c.minute ?? 0) * 60 + Double(c.second ?? 0)) / 86400
        let entries = ti.compactMap { e -> (Int, Double)? in
            guard let i = e["i"] as? Int, let t = (e["t"] as? NSNumber)?.doubleValue else { return nil }
            return (i, t)
        }.sorted { $0.1 < $1.1 }
        guard !entries.isEmpty else { return nil }
        return (entries.last { $0.1 <= now } ?? entries.last!).0
    }

    /// solar: {"si": [{"i": frame, "a": altitude°, "z": azimuth°}]} — match the sun's current position.
    private static func solarBased(_ d: [String: Any]) -> Int? {
        guard let si = d["si"] as? [[String: Any]], !si.isEmpty else { return appearanceFallback(d) }
        let (alt, morning) = sunPosition(Date())
        var best: (Int, Double)?
        for e in si {
            guard let i = e["i"] as? Int,
                  let a = (e["a"] as? NSNumber)?.doubleValue,
                  let z = (e["z"] as? NSNumber)?.doubleValue else { continue }
            let sameHalf = (z < 180) == morning
            let score = abs(a - alt) + (sameHalf ? 0 : 25)
            if best == nil || score < best!.1 { best = (i, score) }
        }
        return best?.0
    }

    private static func appearanceFallback(_ d: [String: Any]) -> Int? {
        (d["ap"] as? [String: Any]).flatMap { appearanceBased($0) }
    }

    /// Approximate solar altitude from local clock time (latitude ≈ 32°, good enough to pick a frame).
    private static func sunPosition(_ date: Date) -> (altitude: Double, morning: Bool) {
        let cal = Calendar.current
        let day = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 180)
        let c = cal.dateComponents([.hour, .minute], from: date)
        let hours = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        let decl = 23.44 * sin((360.0 / 365.0 * (day - 81)) * .pi / 180) * .pi / 180
        let lat = 32.0 * .pi / 180
        let hourAngle = (hours - 12) * 15 * .pi / 180
        let sinAlt = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(hourAngle)
        return (asin(sinAlt) * 180 / .pi, hours < 12)
    }
}
