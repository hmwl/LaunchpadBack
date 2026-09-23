import AppKit
import CoreImage
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
            withAnimation(.easeOut(duration: 0.18)) { self.model.shown = true }
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
        withAnimation(.easeInOut(duration: 0.18)) { model.shown = false }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 190_000_000)
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
        let key = "\(url.path)|\(mod)|\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        if let img = cache[key] { return img }

        guard let src = NSImage(contentsOf: url), src.isValid else { return nil }
        var rect = CGRect(origin: .zero, size: src.size)
        guard let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }

        let target = CGSize(width: max(64, screen.frame.width / 3), height: max(64, screen.frame.height / 3))
        let input = CIImage(cgImage: cg)
        guard input.extent.width > 0, input.extent.height > 0 else { return nil }
        let scale = max(target.width / input.extent.width, target.height / input.extent.height)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(x: scaled.extent.midX - target.width / 2,
                          y: scaled.extent.midY - target.height / 2,
                          width: target.width, height: target.height)
        let blurred = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: 16)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.2,
                kCIInputBrightnessKey: -0.04,
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
        return sorted.first { NSImage(contentsOf: $0)?.isValid == true }
    }
}
