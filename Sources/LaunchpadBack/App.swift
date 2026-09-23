import AppKit
import ServiceManagement
import SwiftUI

@main
struct LaunchpadMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LaunchpadModel()
    private var controller: WindowController!
    private var monitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        // Show the bundled icon as-is in the Dock (macOS 26+ otherwise puts legacy icons on a grey platter).
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        controller = WindowController(model: model)
        model.controller = controller
        model.initialLoad()
        installMonitors()

        HotKeyManager.shared.onTrigger = { [weak self] in self?.controller.toggle() }
        HotKeyManager.shared.apply(HotKeyOption.current)

        controller.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon toggles, exactly like Launchpad.
        controller.toggle()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Presentation options only take effect while we're the active app.
        controller.applyPresentation()
    }

    func applicationDidResignActive(_ notification: Notification) {
        controller.hide(launching: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Event monitors

    private func installMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            let consumed = MainActor.assumeIsolated { self.model.handleKeyDown(e) }
            return consumed ? nil : e
        }
        let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self else { return e }
            let consumed = MainActor.assumeIsolated { self.model.handleScroll(e) }
            return consumed ? nil : e
        }
        let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            guard let self else { return e }
            MainActor.assumeIsolated { self.model.handleFlags(e) }
            return e
        }
        let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self else { return e }
            let consumed = MainActor.assumeIsolated { self.handleMouse(e) }
            return consumed ? nil : e
        }
        monitors = [keys, scroll, flags, mouse].compactMap { $0 }
    }

    private var mouseCaptured = false

    /// Routes raw AppKit mouse events to the model (reliable mouseDown → mouseUp pairing).
    private func handleMouse(_ e: NSEvent) -> Bool {
        let win = controller.window
        guard controller.isVisible, win.attachedSheet == nil else {
            mouseCaptured = false
            return false
        }
        let screenPt: NSPoint = e.window.map { $0.convertPoint(toScreen: e.locationInWindow) } ?? e.locationInWindow
        let local = win.convertPoint(fromScreen: screenPt)
        let h = win.contentView?.bounds.height ?? win.frame.height
        let pt = CGPoint(x: local.x, y: h - local.y)

        switch e.type {
        case .leftMouseDown:
            guard e.window === win else { return false }
            mouseCaptured = model.mouseDown(at: pt, time: e.timestamp)
            return mouseCaptured
        case .leftMouseDragged:
            guard mouseCaptured else { return false }
            model.mouseDragged(to: pt, time: e.timestamp)
            return true
        case .leftMouseUp:
            guard mouseCaptured else { return false }
            mouseCaptured = false
            model.mouseUp(at: pt, time: e.timestamp)
            return true
        default:
            return false
        }
    }

    // MARK: Menus

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.t("退出启动台", "Quit Launchpad"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let gridItem = NSMenuItem(title: L10n.t("图标布局", "Grid Size"), action: nil, keyEquivalent: "")
        let gridMenu = NSMenu()
        for (c, r) in [(7, 5), (8, 5), (8, 6), (9, 6), (10, 6), (6, 4), (5, 4)] {
            let title = "\(c) × \(r)" + (c == 7 && r == 5 ? L10n.t("（默认）", " (Default)") : "")
            let it = NSMenuItem(title: title, action: #selector(chooseGrid(_:)), keyEquivalent: "")
            it.target = self
            it.tag = c * 100 + r
            it.state = (model.columns == c && model.rows == r) ? .on : .off
            gridMenu.addItem(it)
        }
        gridItem.submenu = gridMenu
        menu.addItem(gridItem)

        let hkItem = NSMenuItem(title: L10n.t("快捷键", "Hotkey"), action: nil, keyEquivalent: "")
        let hkMenu = NSMenu()
        let current = HotKeyOption.current
        for opt in HotKeyOption.allCases {
            let it = NSMenuItem(title: opt.title, action: #selector(chooseHotKey(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = opt.rawValue
            it.state = opt == current ? .on : .off
            hkMenu.addItem(it)
        }
        hkItem.submenu = hkMenu
        menu.addItem(hkItem)

        let glass = NSMenuItem(title: L10n.t("液态玻璃效果", "Liquid Glass Effect"), action: #selector(toggleGlass(_:)), keyEquivalent: "")
        glass.target = self
        glass.state = model.liquidGlass ? .on : .off
        if !LaunchpadModel.glassSupported {
            glass.isEnabled = false
            glass.toolTip = L10n.t("需要 macOS 26 或更高版本", "Requires macOS 26 or later")
        }
        menu.addItem(glass)

        menu.addItem(.separator())

        let login = NSMenuItem(title: L10n.t("登录时打开", "Open at Login"), action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let rescan = NSMenuItem(title: L10n.t("重新扫描应用", "Rescan Apps"), action: #selector(rescan(_:)), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)

        let reset = NSMenuItem(title: L10n.t("重置布局…", "Reset Layout…"), action: #selector(resetLayout(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        return menu
    }

    @objc private func toggleGlass(_ sender: NSMenuItem) {
        model.setLiquidGlass(!model.liquidGlass)
    }

    @objc private func chooseGrid(_ sender: NSMenuItem) {
        model.setGrid(cols: sender.tag / 100, rows: sender.tag % 100)
    }

    @objc private func chooseHotKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let opt = HotKeyOption(rawValue: raw) else { return }
        UserDefaults.standard.set(raw, forKey: "hotkey")
        HotKeyManager.shared.apply(opt)
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            present(NSAlert(error: error))
        }
    }

    @objc private func rescan(_ sender: NSMenuItem) {
        IconCache.shared.clear()
        model.refreshApps()
    }

    @objc private func resetLayout(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = L10n.t("重置启动台布局？", "Reset the Launchpad layout?")
        alert.informativeText = L10n.t("所有文件夹和自定排列都会恢复为默认。", "All folders and custom arrangements will be restored to default.")
        alert.addButton(withTitle: L10n.t("重置", "Reset"))
        alert.addButton(withTitle: L10n.t("取消", "Cancel"))
        present(alert) { [weak self] ok in
            if ok { self?.model.resetLayout() }
        }
    }

    /// Alerts must never end up hidden behind the full-screen Launchpad window:
    /// attach them as a sheet while Launchpad is showing, otherwise run them normally.
    private func present(_ alert: NSAlert, completion: ((Bool) -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if controller.isVisible {
            alert.beginSheetModal(for: controller.window) { resp in
                completion?(resp == .alertFirstButtonReturn)
            }
        } else {
            alert.window.level = .modalPanel
            completion?(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
