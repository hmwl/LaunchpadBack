import AppKit
import SwiftUI

@MainActor
final class LaunchpadModel: ObservableObject {
    // Layout
    @Published var pages: [[LPItem]] = [[]]
    @Published var currentPage = 0
    @Published var searchPage = 0
    @Published var folderPage = 0
    @Published var pageOffset: CGFloat = 0

    // Search
    @Published var searchText = "" {
        didSet { if searchText != oldValue { searchChanged() } }
    }
    @Published private(set) var searchResults: [LPItem] = []

    // Interaction state
    @Published var isEditing = false
    @Published var openFolderID: String?
    @Published var selectedSlot: Int?
    @Published var drag: DragState?
    @Published var pressedID: String?
    @Published var shown = false
    @Published var focusSearchToken = 0
    /// The user clicked into the search field (shows the highlighted/active look).
    @Published var searchEngaged = false
    /// Where the open folder zooms from / back to (its icon on the page), in unit coordinates.
    @Published var folderAnchor: UnitPoint = .center
    /// Liquid Glass look (macOS 26+), toggled from the Dock menu. Off = pure macOS 15 look.
    @Published var liquidGlass = UserDefaults.standard.bool(forKey: "liquidGlass")
    /// Folder panel fully expanded (false while it morphs out of / back into its icon).
    @Published var folderExpanded = false
    /// Frame of the opened folder's tile on the page (the morph's start / end point).
    var folderIconRect: CGRect = .zero

    static var glassSupported: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }
    var glassActive: Bool { liquidGlass && Self.glassSupported }

    func setLiquidGlass(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "liquidGlass")
        withAnimation(.easeInOut(duration: 0.2)) { liquidGlass = on }
    }

    // Environment
    @Published var wallpaper: NSImage?
    @Published var dockInset: CGFloat = 70
    @Published var columns: Int
    @Published var rows: Int

    var folderNameEditing = false
    weak var controller: WindowController?
    var viewSize: CGSize = .zero

    private var press: PressState?
    private var longPressTask: Task<Void, Never>?
    private var edgeTask: Task<Void, Never>?
    private var edgeDirection = 0
    private var mergeTask: Task<Void, Never>?
    private var mergeCandidateID: String?
    private var reorderTask: Task<Void, Never>?
    private var pendingReorder: Int?
    private var folderExitTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var wheelAccum: CGFloat = 0
    private var lastWheelFlip = Date.distantPast
    private var rawScrollOffset: CGFloat = 0
    private var lastScrollDelta: CGFloat = 0
    private var optionEditing = false
    private(set) var allApps: [AppEntry] = []

    init() {
        let d = UserDefaults.standard
        let c = d.integer(forKey: "columns")
        let r = d.integer(forKey: "rows")
        columns = c > 0 ? c : 7
        rows = r > 0 ? r : 5
    }

    // MARK: - Capacities / contexts

    var mainCapacity: Int { columns * rows }
    var folderCapacity: Int { columns * min(LPRatio.folderMaxRows, rows) }

    var ctx: Ctx {
        if let f = openFolderID { return .folder(f) }
        if !searchText.isEmpty { return .search }
        return .main
    }

    func capacity(for c: Ctx) -> Int {
        if case .folder = c { return folderCapacity }
        return mainCapacity
    }

    func activePage(for c: Ctx) -> Int {
        switch c {
        case .main: return currentPage
        case .search: return searchPage
        case .folder: return folderPage
        }
    }

    var activePage: Int { activePage(for: ctx) }

    func setActivePage(_ p: Int) {
        switch ctx {
        case .main: currentPage = p
        case .search: searchPage = p
        case .folder: folderPage = p
        }
    }

    func pageCount(_ c: Ctx) -> Int {
        switch c {
        case .main:
            return max(1, pages.count)
        case .search:
            return max(1, (searchResults.count + mainCapacity - 1) / mainCapacity)
        case .folder(let id):
            let n = (folder(id)?.apps.count ?? 0) + (drag?.fromFolderID == id ? 1 : 0)
            return max(1, (n + folderCapacity - 1) / folderCapacity)
        }
    }

    func items(in c: Ctx, page: Int) -> [LPItem] {
        switch c {
        case .main:
            return pages.indices.contains(page) ? pages[page] : []
        case .search:
            return slice(searchResults, page: page, cap: mainCapacity)
        case .folder(let id):
            guard let f = folder(id) else { return [] }
            return slice(f.apps.map { LPItem.app($0) }, page: page, cap: folderCapacity)
        }
    }

    private func slice(_ a: [LPItem], page: Int, cap: Int) -> [LPItem] {
        let s = page * cap
        guard s >= 0, s < a.count else { return [] }
        return Array(a[s..<min(a.count, s + cap)])
    }

    /// Items with their visual slot; leaves a gap where a dragged item would land.
    func displayEntries(ctx c: Ctx, page: Int) -> [PlacedItem] {
        let list = items(in: c, page: page)
        let cap = capacity(for: c)
        var placeholder: Int?
        if let d = drag, c == ctx, page == activePage(for: c) { placeholder = d.targetIndex }
        var out: [PlacedItem] = []
        var slot = 0
        for it in list {
            if let ph = placeholder, slot == ph { slot += 1 }
            if slot >= cap { break }
            out.append(PlacedItem(item: it, slot: slot))
            slot += 1
        }
        return out
    }

    func visuals(ctx c: Ctx, page: Int, time: Double) -> IconVisuals {
        let active = c == ctx && page == activePage(for: c)
        var editing = isEditing
        if case .search = c { editing = false }
        return IconVisuals(editing: editing,
                           pressedID: pressedID,
                           selectedSlot: active ? selectedSlot : nil,
                           mergeTargetID: drag?.mergeTargetID,
                           time: time,
                           glass: glassActive)
    }

    // MARK: - Folders

    func folder(_ id: String) -> FolderEntry? {
        for page in pages {
            for item in page {
                if case .folder(let f) = item, f.id == id { return f }
            }
        }
        return nil
    }

    func updateFolder(_ id: String, _ transform: (inout FolderEntry) -> Void) {
        for p in pages.indices {
            if let i = pages[p].firstIndex(where: { $0.id == id }), case .folder(var f) = pages[p][i] {
                transform(&f)
                pages[p][i] = .folder(f)
                return
            }
        }
    }

    func folderLayout(metrics m: GridMetrics, size: CGSize) -> FolderLayout? {
        guard let fid = openFolderID, let f = folder(fid) else { return nil }
        let extra = drag?.fromFolderID == fid ? 1 : 0
        return FolderLayout.make(main: m, screen: size, appCount: f.apps.count + extra)
    }

    func openFolder(_ id: String) {
        if viewSize != .zero, let idx = pages.indices.contains(currentPage) ? pages[currentPage].firstIndex(where: { $0.id == id }) : nil {
            let m = mainMetrics
            let c = m.iconCenter(idx)
            folderAnchor = UnitPoint(x: c.x / viewSize.width, y: c.y / viewSize.height)
            let box = m.iconSize * 0.805
            folderIconRect = CGRect(x: c.x - box / 2, y: c.y - box / 2, width: box, height: box)
        } else {
            folderAnchor = .center
            folderIconRect = CGRect(x: viewSize.width / 2 - 40, y: viewSize.height / 2 - 40, width: 80, height: 80)
        }
        folderPage = 0
        pageOffset = 0
        selectedSlot = nil
        if glassActive {
            // Glass: the panel is born at the folder tile's frame, then morphs open.
            folderExpanded = false
            openFolderID = id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard let self, self.openFolderID == id else { return }
                withAnimation(.smooth(duration: 0.3)) { self.folderExpanded = true }
            }
        } else {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.92)) {
                openFolderID = id
                folderExpanded = true
            }
        }
    }

    func closeFolder(animated: Bool = true) {
        guard let id = openFolderID else { return }
        endFolderRename()
        selectedSlot = nil
        if animated && glassActive {
            // Glass: morph back into the tile, then drop the overlay.
            withAnimation(.smooth(duration: 0.26)) { folderExpanded = false }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 270_000_000)
                guard let self, self.openFolderID == id, !self.folderExpanded else { return }
                self.openFolderID = nil
                self.folderPage = 0
                self.pageOffset = 0
            }
        } else {
            if animated {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.95)) {
                    openFolderID = nil
                    folderExpanded = false
                }
            } else {
                openFolderID = nil
                folderExpanded = false
            }
            folderPage = 0
            pageOffset = 0
        }
        focusSearchSoon()
    }

    func renameFolder(_ id: String, to name: String) {
        updateFolder(id) { $0.name = name }
        save()
    }

    func endFolderRename() {
        guard folderNameEditing else { return }
        folderNameEditing = false
        if let fid = openFolderID, let f = folder(fid),
           f.name.trimmingCharacters(in: .whitespaces).isEmpty {
            updateFolder(fid) { $0.name = L10n.t("未命名文件夹", "Untitled Folder") }
            save()
        }
        focusSearchSoon()
    }

    // MARK: - Loading

    func initialLoad() {
        let apps = AppScanner.scan()
        allApps = apps
        let saved = LayoutStore.load()
        pages = LayoutStore.build(apps: apps, saved: saved, capacity: mainCapacity)
        if saved == nil { save() }
    }

    func refreshApps() {
        Task.detached(priority: .userInitiated) {
            let apps = AppScanner.scan()
            await MainActor.run { self.applyScan(apps) }
        }
    }

    private func applyScan(_ apps: [AppEntry]) {
        guard drag == nil else { return }
        allApps = apps
        let merged = LayoutStore.merge(pages: pages, apps: apps, capacity: mainCapacity)
        if merged != pages {
            pages = merged
            currentPage = min(currentPage, pages.count - 1)
            save()
        }
    }

    func setGrid(cols: Int, rows r: Int) {
        columns = cols
        rows = r
        UserDefaults.standard.set(cols, forKey: "columns")
        UserDefaults.standard.set(r, forKey: "rows")
        pages = LayoutStore.reflow(pages, capacity: mainCapacity)
        currentPage = min(currentPage, pages.count - 1)
        save()
    }

    func resetLayout() {
        LayoutStore.delete()
        pages = LayoutStore.defaultLayout(apps: allApps, capacity: mainCapacity)
        currentPage = 0
        save()
    }

    func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            LayoutStore.save(self.pages)
        }
    }

    // MARK: - Show / hide

    func prepareForShow() {
        resetTransient()
        currentPage = max(0, min(currentPage, pages.count - 1))
        refreshApps()
        focusSearchSoon()
    }

    func didHide() {
        resetTransient()
    }

    private func resetTransient() {
        longPressTask?.cancel(); edgeTask?.cancel(); mergeTask?.cancel(); folderExitTask?.cancel()
        press = nil
        if drag != nil { commitDropImmediately() }
        searchText = ""
        searchEngaged = false
        openFolderID = nil
        folderExpanded = false
        folderNameEditing = false
        isEditing = false
        optionEditing = false
        pressedID = nil
        selectedSlot = nil
        pageOffset = 0
        folderPage = 0
    }

    func focusSearchSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            self?.focusSearchToken &+= 1
        }
    }

    // MARK: - Search

    private func searchChanged() {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        searchPage = 0
        pageOffset = 0
        if q.isEmpty {
            searchResults = []
            selectedSlot = nil
            return
        }
        if openFolderID != nil { closeFolder(animated: false) }
        if isEditing { isEditing = false }

        var ordered: [AppEntry] = []
        for page in pages { for item in page { ordered += item.apps } }

        var scored: [(AppEntry, Int)] = []
        for a in ordered {
            var best = Int.max
            for (i, k) in a.searchKeys.enumerated() {
                if k.hasPrefix(q) { best = min(best, i == 0 ? 0 : 1) }
                else if k.contains(" " + q) { best = min(best, 2) }
                else if k.contains(q) { best = min(best, 3) }
            }
            if best < Int.max { scored.append((a, best)) }
        }
        scored.sort { l, r in
            if l.1 != r.1 { return l.1 < r.1 }
            return l.0.name.localizedStandardCompare(r.0.name) == .orderedAscending
        }
        searchResults = scored.map { LPItem.app($0.0) }
        selectedSlot = searchResults.isEmpty ? nil : 0
    }

    // MARK: - Actions

    func launch(_ app: AppEntry) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: cfg) { _, error in
            if let error {
                Task { @MainActor in let a = NSAlert(error: error); a.window.level = .modalPanel; a.runModal() }
            }
        }
        controller?.hide(launching: true)
    }

    func confirmDelete(_ app: AppEntry) {
        guard let window = controller?.window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("是否要删除“\(app.name)”？", "Are you sure you want to delete “\(app.name)”?")
        alert.informativeText = L10n.t("删除此 App 也将删除其数据。", "Deleting this app will also delete its data.")
        alert.icon = IconCache.shared.icon(for: app)
        alert.addButton(withTitle: L10n.t("删除", "Delete"))
        alert.addButton(withTitle: L10n.t("取消", "Cancel"))
        alert.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            self.performDelete(app)
        }
    }

    private func performDelete(_ app: AppEntry) {
        NSWorkspace.shared.recycle([app.url]) { _, error in
            Task { @MainActor in
                if let error {
                    self.showError(error)
                } else {
                    self.removeApp(app.id)
                }
            }
        }
    }

    private func showError(_ error: Error) {
        guard let window = controller?.window else { return }
        NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
    }

    private func removeApp(_ id: String) {
        pages = pages.map { page in
            page.compactMap { item -> LPItem? in
                switch item {
                case .app(let a): return a.id == id ? nil : item
                case .folder(var f):
                    f.apps.removeAll { $0.id == id }
                    return .folder(f)
                }
            }
        }
        normalize()
        save()
    }

    func jump(to page: Int) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.92)) {
            setActivePage(max(0, min(pageCount(ctx) - 1, page)))
            pageOffset = 0
        }
        selectedSlot = nil
    }

    private func changePage(_ dir: Int) {
        let target = activePage + dir
        guard target >= 0, target < pageCount(ctx) else { return }
        jump(to: target)
    }

    // MARK: - Pointer

    // Mouse input comes straight from AppKit (see AppDelegate's event monitor), which guarantees
    // every mouseDown gets its mouseUp — SwiftUI gestures can be cancelled silently mid-drag,
    // which left dragged icons stuck on screen and made folder creation impossible.

    private var pressStart: CGPoint = .zero
    private var lastMouse: (p: CGPoint, t: TimeInterval) = (.zero, 0)
    private var mouseVelocity: CGFloat = 0

    var mainMetrics: GridMetrics { GridMetrics.main(size: viewSize, cols: columns, rows: rows) }

    /// Returns false when the click belongs to a text field (search / folder title) and must pass through.
    func mouseDown(at pt: CGPoint, time: TimeInterval) -> Bool {
        guard viewSize != .zero else { return false }
        let m = mainMetrics
        if passthroughRect(metrics: m).contains(where: { $0.contains(pt) }) {
            if openFolderID == nil { withAnimation(.easeOut(duration: 0.12)) { searchEngaged = true } }
            return false
        }
        if searchEngaged && searchText.isEmpty { withAnimation(.easeOut(duration: 0.12)) { searchEngaged = false } }
        if openFolderID == nil, let i = pageDotIndex(at: pt) {
            jump(to: i)
            return true
        }
        if press != nil { mouseUp(at: pt, time: time) }   // never leave a stale press behind
        pressStart = pt
        lastMouse = (pt, time)
        mouseVelocity = 0
        beginPress(at: pt, metrics: m, size: viewSize)
        return true
    }

    func mouseDragged(to pt: CGPoint, time: TimeInterval) {
        guard var p = press else { return }
        let m = mainMetrics
        let size = viewSize
        let dt = max(0.001, time - lastMouse.t)
        mouseVelocity = mouseVelocity * 0.4 + ((pt.x - lastMouse.p.x) / CGFloat(dt)) * 0.6
        lastMouse = (pt, time)
        let tx = pt.x - pressStart.x, ty = pt.y - pressStart.y

        if p.mode == .pending || p.mode == .longPressed {
            guard hypot(tx, ty) > 5 else { return }
            longPressTask?.cancel()
            pressedID = nil
            switch p.hit {
            case .item(let c, let index, let item) where c != .search:
                p.mode = .dragging
                press = p
                beginItemDrag(item: item, ctx: c, index: index, at: pt, metrics: m, size: size)
                return
            case .item, .empty, .folderEmpty:
                p.mode = .swipe
                press = p
            default:
                return
            }
        }

        switch p.mode {
        case .dragging:
            updateDrag(at: pt, metrics: m, size: size)
        case .swipe:
            pageOffset = rubberBand(tx)
        default:
            break
        }
    }

    func mouseUp(at pt: CGPoint, time: TimeInterval) {
        longPressTask?.cancel()
        pressedID = nil
        guard let p = press else { return }
        press = nil
        let m = mainMetrics
        switch p.mode {
        case .pending:
            handleTap(p.hit)
        case .longPressed:
            break
        case .swipe:
            let predicted = (pt.x - pressStart.x) + mouseVelocity * 0.25
            finishSwipe(predicted: predicted, width: currentPageWidth(metrics: m, size: viewSize))
        case .dragging:
            if let d = drag, !d.dropping { updateDrag(at: pt, metrics: m, size: viewSize) }
            endItemDrag(metrics: m, size: viewSize)
        }
    }

    /// Areas owned by real text fields.
    private func passthroughRect(metrics m: GridMetrics) -> [CGRect] {
        if let l = folderLayout(metrics: m, size: viewSize) { return [l.titleRect] }
        let k = min(1.3, max(0.8, viewSize.height / 982))
        let w = 250 * k, h = 24 * k
        return [CGRect(x: viewSize.width / 2 - w / 2, y: viewSize.height * LPRatio.searchY - h / 2, width: w, height: h)]
    }

    private func pageDotIndex(at pt: CGPoint) -> Int? {
        let c = ctx
        let n = pageCount(c)
        guard n > 1 else { return nil }
        let pitch: CGFloat = 19
        let total = CGFloat(n) * pitch
        let x0 = viewSize.width / 2 - total / 2
        let y = viewSize.height * LPRatio.dotsY
        guard abs(pt.y - y) <= 10, pt.x >= x0, pt.x < x0 + total else { return nil }
        return Int((pt.x - x0) / pitch)
    }

    private func currentPageWidth(metrics m: GridMetrics, size: CGSize) -> CGFloat {
        if let l = folderLayout(metrics: m, size: size) { return l.panel.width }
        return max(1, size.width)
    }

    private func beginPress(at pt: CGPoint, metrics m: GridMetrics, size: CGSize) {
        if folderNameEditing { endFolderRename() }
        let hit = hitTest(pt, metrics: m, size: size)
        press = PressState(hit: hit, mode: .pending)
        if case .item(let c, _, let item) = hit {
            pressedID = item.id
            if c != .search {
                longPressTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard let self, !Task.isCancelled, var p = self.press, p.mode == .pending else { return }
                    p.mode = .longPressed
                    self.press = p
                    self.pressedID = nil
                    withAnimation(.easeInOut(duration: 0.15)) { self.isEditing = true }
                }
            }
        }
    }

    private func hitTest(_ pt: CGPoint, metrics m: GridMetrics, size: CGSize) -> HitTarget {
        if let fid = openFolderID, let layout = folderLayout(metrics: m, size: size) {
            if !layout.panel.contains(pt) && !layout.titleRect.contains(pt) { return .outsideFolder }
            if let h = hitItem(pt, ctx: .folder(fid), page: folderPage, grid: layout.grid) { return h }
            return .folderEmpty
        }
        let c = ctx
        if let h = hitItem(pt, ctx: c, page: activePage(for: c), grid: m) { return h }
        return .empty
    }

    private func hitItem(_ pt: CGPoint, ctx c: Ctx, page: Int, grid: GridMetrics) -> HitTarget? {
        let list = items(in: c, page: page)
        let editing = isEditing && c != .search
        for (i, item) in list.enumerated() where i < grid.capacity {
            if editing, case .app(let a) = item, a.isAppStore, grid.deleteRect(i).contains(pt) {
                return .delete(a)
            }
        }
        for (i, item) in list.enumerated() where i < grid.capacity {
            if grid.hitRect(i).contains(pt) { return .item(c, index: i, item: item) }
        }
        return nil
    }

    private func handleTap(_ hit: HitTarget) {
        switch hit {
        case .delete(let app):
            confirmDelete(app)
        case .item(let c, _, let item):
            switch item {
            case .folder(let f):
                if c == .main { openFolder(f.id) }
            case .app(let a):
                if isEditing {
                    withAnimation(.easeOut(duration: 0.15)) { isEditing = false }
                } else {
                    launch(a)
                }
            }
        case .empty:
            if isEditing {
                withAnimation(.easeOut(duration: 0.15)) { isEditing = false }
            } else {
                controller?.hide()
            }
        case .outsideFolder:
            closeFolder()
        case .folderEmpty:
            if isEditing { withAnimation(.easeOut(duration: 0.15)) { isEditing = false } }
        }
    }

    // MARK: - Paging

    private func rubberBand(_ x: CGFloat) -> CGFloat {
        let page = activePage, count = pageCount(ctx)
        if (page == 0 && x > 0) || (page >= count - 1 && x < 0) { return x * 0.3 }
        return x
    }

    private func finishSwipe(predicted: CGFloat, width: CGFloat) {
        let count = pageCount(ctx)
        var target = activePage
        let off = pageOffset
        let proj = abs(predicted) > abs(off) ? predicted : off
        if proj < -width * 0.3 { target += 1 } else if proj > width * 0.3 { target -= 1 }
        target = max(0, min(count - 1, target))
        if target != activePage { selectedSlot = nil }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) {
            setActivePage(target)
            pageOffset = 0
        }
    }

    // MARK: - Drag & drop

    private func beginItemDrag(item: LPItem, ctx c: Ctx, index: Int, at pt: CGPoint, metrics m: GridMetrics, size: CGSize) {
        var grid = m
        var fromFolder: String?
        switch c {
        case .folder(let fid):
            guard let layout = folderLayout(metrics: m, size: size) else { return }
            grid = layout.grid
            fromFolder = fid
        case .main:
            break
        case .search:
            return
        }
        let center = grid.iconCenter(index)

        switch c {
        case .main:
            guard pages.indices.contains(currentPage), index < pages[currentPage].count else { return }
            pages[currentPage].remove(at: index)
        case .folder(let fid):
            let absIndex = folderPage * folderCapacity + index
            updateFolder(fid) { f in if absIndex < f.apps.count { f.apps.remove(at: absIndex) } }
        case .search:
            return
        }

        drag = DragState(item: item, location: pt,
                         grabOffset: CGSize(width: pt.x - center.x, height: pt.y - center.y),
                         fromFolderID: fromFolder, targetIndex: index, mergeTargetID: nil)
        selectedSlot = nil
        if !isEditing { withAnimation(.easeInOut(duration: 0.15)) { isEditing = true } }
    }

    private func updateDrag(at pt: CGPoint, metrics m: GridMetrics, size: CGSize) {
        guard var d = drag, !d.dropping else { return }
        d.location = pt
        drag = d

        // Inside an open folder
        if let fid = openFolderID, let layout = folderLayout(metrics: m, size: size) {
            if !layout.panel.insetBy(dx: -8, dy: -8).contains(pt) {
                if folderExitTask == nil {
                    folderExitTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.folderExitTask = nil
                        self.closeFolder()
                        if let d = self.drag { self.updateDrag(at: d.location, metrics: m, size: size) }
                    }
                }
                return
            }
            folderExitTask?.cancel()
            folderExitTask = nil
            let s = layout.grid.nearestSlot(to: pt)
            let count = items(in: .folder(fid), page: folderPage).count
            let t = min(s, count)
            if t != d.targetIndex {
                withAnimation(.easeOut(duration: 0.14)) { drag?.targetIndex = t }
            }
            return
        }

        // Page flipping at screen edges
        let edgeZone = max(24, m.origin.x * 0.45)
        let dir = pt.x < edgeZone ? -1 : (pt.x > size.width - edgeZone ? 1 : 0)
        if dir != edgeDirection {
            edgeDirection = dir
            edgeTask?.cancel()
            edgeTask = nil
            if dir != 0 { startEdgeTimer(dir, metrics: m, size: size) }
        }
        if dir != 0 { return }

        let list = pages.indices.contains(currentPage) ? pages[currentPage] : []
        let s = m.nearestSlot(to: pt)

        // Which icon is actually drawn under the cursor right now (placeholder-aware).
        let hovered = displayEntries(ctx: .main, page: currentPage).first(where: { $0.slot == s })

        // Hovering over an app/folder icon → create / add to folder. The zone covers almost the whole
        // icon (and a bit more once armed), so the target never has to be "chased".
        let isApp: Bool = { if case .app = d.item { return true }; return false }()
        if let e = hovered {
            let body = m.iconRect(s)
            if isApp {
                let armed = mergeCandidateID == e.item.id
                let zone = body.insetBy(dx: m.iconSize * (armed ? -0.12 : 0.06), dy: m.iconSize * (armed ? -0.12 : 0.06))
                if zone.contains(pt) {
                    cancelReorder()
                    if !armed {
                        mergeTask?.cancel()
                        mergeCandidateID = e.item.id
                        if d.mergeTargetID != nil {
                            withAnimation(.easeOut(duration: 0.12)) { drag?.mergeTargetID = nil }
                        }
                        let id = e.item.id
                        mergeTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 160_000_000)
                            guard let self, !Task.isCancelled, self.mergeCandidateID == id else { return }
                            withAnimation(.easeOut(duration: 0.16)) { self.drag?.mergeTargetID = id }
                        }
                    }
                    return
                }
            } else if body.insetBy(dx: -m.iconSize * 0.05, dy: -m.iconSize * 0.05).contains(pt) {
                // Folders can't be nested: hovering a folder over an icon waits a bit longer, then swaps.
                clearMerge()
                scheduleReorder(to: min(s, list.count), delay: 350_000_000)
                return
            }
        }
        clearMerge()

        // In the gaps between icons: reorder after a short rest so passing through doesn't shuffle things.
        let t = min(s, list.count)
        if t == d.targetIndex {
            cancelReorder()
        } else {
            scheduleReorder(to: t, delay: 220_000_000)
        }
    }

    private func scheduleReorder(to t: Int, delay: UInt64) {
        guard drag?.targetIndex != t else { cancelReorder(); return }
        guard pendingReorder != t else { return }
        reorderTask?.cancel()
        pendingReorder = t
        reorderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, self.pendingReorder == t, self.drag != nil else { return }
            self.pendingReorder = nil
            withAnimation(.easeOut(duration: 0.18)) { self.drag?.targetIndex = t }
        }
    }

    private func cancelReorder() {
        reorderTask?.cancel()
        reorderTask = nil
        pendingReorder = nil
    }

    private func clearMerge() {
        mergeTask?.cancel()
        mergeTask = nil
        mergeCandidateID = nil
        if drag?.mergeTargetID != nil {
            withAnimation(.easeOut(duration: 0.15)) { drag?.mergeTargetID = nil }
        }
    }

    private func startEdgeTimer(_ dir: Int, metrics m: GridMetrics, size: CGSize) {
        edgeTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: first ? 550_000_000 : 900_000_000)
                first = false
                guard let self, !Task.isCancelled, self.drag != nil else { return }
                self.flipPageDuringDrag(dir)
            }
        }
    }

    private func flipPageDuringDrag(_ dir: Int) {
        let target = currentPage + dir
        if target < 0 { return }
        if target >= pages.count {
            if pages.last?.isEmpty == true { return }
            pages.append([])
        }
        clearMerge()
        cancelReorder()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.92)) {
            currentPage = target
            drag?.targetIndex = min(pages[target].count, mainCapacity - 1)
        }
    }

    private func endItemDrag(metrics m: GridMetrics, size: CGSize) {
        edgeTask?.cancel(); edgeTask = nil; edgeDirection = 0
        folderExitTask?.cancel(); folderExitTask = nil
        cancelReorder()
        let candidate = mergeCandidateID
        mergeTask?.cancel(); mergeTask = nil; mergeCandidateID = nil
        guard var d = drag else { return }
        if d.mergeTargetID == nil, openFolderID == nil, let candidate { d.mergeTargetID = candidate }

        let dest: CGPoint
        if let layout = folderLayout(metrics: m, size: size) {
            dest = layout.grid.iconCenter(d.targetIndex)
        } else if let mid = d.mergeTargetID,
                  let slot = displayEntries(ctx: .main, page: currentPage).first(where: { $0.item.id == mid })?.slot {
            dest = m.iconCenter(slot)
        } else {
            let count = pages.indices.contains(currentPage) ? pages[currentPage].count : 0
            dest = m.iconCenter(min(d.targetIndex, count, mainCapacity - 1))
        }

        let merging = d.mergeTargetID != nil && openFolderID == nil
        drag = d
        let duration = merging ? 0.15 : 0.12
        withAnimation(.easeOut(duration: duration)) {
            drag?.dropping = true
            drag?.mergingIn = merging
            drag?.location = CGPoint(x: dest.x + d.grabOffset.width, y: dest.y + d.grabOffset.height)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000) + 10_000_000)
            self?.commitDrop()
        }
    }

    private func commitDropImmediately() {
        commitDrop()
    }

    private func commitDrop() {
        guard let d = drag else { return }
        var openAfter: String?

        if let fid = openFolderID, case .app(let a) = d.item {
            let base = folderPage * folderCapacity
            updateFolder(fid) { f in
                f.apps.insert(a, at: min(base + d.targetIndex, f.apps.count))
            }
        } else {
            if !pages.indices.contains(currentPage) {
                pages.append([])
                currentPage = pages.count - 1
            }
            if let mid = d.mergeTargetID, case .app(let dragged) = d.item,
               let idx = pages[currentPage].firstIndex(where: { $0.id == mid }) {
                switch pages[currentPage][idx] {
                case .folder(var f):
                    f.apps.append(dragged)
                    pages[currentPage][idx] = .folder(f)
                case .app(let target):
                    let f = FolderEntry(id: UUID().uuidString,
                                        name: Categories.folderName([target, dragged]),
                                        apps: [target, dragged])
                    pages[currentPage][idx] = .folder(f)
                    openAfter = f.id
                }
            } else {
                let idx = min(d.targetIndex, pages[currentPage].count)
                pages[currentPage].insert(d.item, at: idx)
            }
        }

        drag = nil
        normalize()
        save()
        if let openAfter {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self?.openFolder(openAfter)
            }
        }
    }

    /// Dissolves 0/1-app folders, cascades overflow to the next page and removes empty pages.
    private func normalize() {
        let cleaned: [[LPItem]] = pages.map { page in
            page.compactMap { item -> LPItem? in
                if case .folder(let f) = item { return LayoutStore.normalizeFolder(f) }
                return item
            }
        }
        var emptyBefore = 0
        for (i, p) in cleaned.enumerated() where i < currentPage && p.isEmpty { emptyBefore += 1 }
        let reflowed = LayoutStore.reflow(cleaned, capacity: mainCapacity)
        pages = reflowed
        currentPage = max(0, min(reflowed.count - 1, currentPage - emptyBefore))
        if let fid = openFolderID, folder(fid) == nil { openFolderID = nil }
    }

    // MARK: - Keyboard / scroll

    func handleKeyDown(_ e: NSEvent) -> Bool {
        guard controller?.isVisible == true else { return false }
        let code = e.keyCode
        let cmd = e.modifierFlags.contains(.command)

        if folderNameEditing {
            if code == 53 || code == 36 || code == 76 {
                endFolderRename()
                return true
            }
            return false
        }
        if drag != nil { return true }

        switch code {
        case 53: // esc
            escape()
            return true
        case 36, 76: // return / enter
            activateSelection()
            return true
        case 123: // ←
            if cmd { changePage(-1) } else { moveSelection(dx: -1, dy: 0) }
            return true
        case 124: // →
            if cmd { changePage(1) } else { moveSelection(dx: 1, dy: 0) }
            return true
        case 125: // ↓
            moveSelection(dx: 0, dy: 1)
            return true
        case 126: // ↑
            moveSelection(dx: 0, dy: -1)
            return true
        default:
            return false
        }
    }

    private func escape() {
        if openFolderID != nil {
            closeFolder()
        } else if isEditing {
            withAnimation(.easeOut(duration: 0.15)) { isEditing = false }
        } else if !searchText.isEmpty || searchEngaged {
            searchText = ""
            withAnimation(.easeOut(duration: 0.12)) { searchEngaged = false }
        } else {
            controller?.hide()
        }
    }

    private func activateSelection() {
        let list = items(in: ctx, page: activePage)
        guard let i = selectedSlot ?? (ctx == .search && !list.isEmpty ? 0 : nil), i < list.count else { return }
        switch list[i] {
        case .app(let a):
            launch(a)
        case .folder(let f):
            openFolder(f.id)
            selectedSlot = 0
        }
    }

    private func moveSelection(dx: Int, dy: Int) {
        let c = ctx
        let list = items(in: c, page: activePage)
        guard let cur = selectedSlot, cur < list.count else {
            selectedSlot = list.isEmpty ? nil : 0
            return
        }
        if dx != 0 {
            let n = cur + dx
            if n >= 0 && n < list.count {
                selectedSlot = n
            } else if n < 0 && activePage > 0 {
                jump(to: activePage - 1)
                selectedSlot = max(0, items(in: c, page: activePage).count - 1)
            } else if n >= list.count && activePage < pageCount(c) - 1 {
                jump(to: activePage + 1)
                selectedSlot = 0
            }
        } else {
            let n = cur + dy * columns
            if n >= 0 && n < list.count {
                selectedSlot = n
            } else if dy > 0 && cur / columns < (list.count - 1) / columns {
                selectedSlot = list.count - 1
            }
        }
    }

    func handleScroll(_ e: NSEvent) -> Bool {
        guard controller?.isVisible == true else { return false }
        guard drag == nil, press == nil else { return true }
        if !e.momentumPhase.isEmpty { return true }

        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        var width = max(1, viewSize.width)
        if let l = folderLayout(metrics: mainMetrics, size: viewSize) { width = l.panel.width }

        if e.hasPreciseScrollingDeltas && !e.phase.isEmpty {
            // Trackpad: follow the fingers.
            var d = abs(dx) >= abs(dy) ? dx : dy
            if !e.isDirectionInvertedFromDevice { d = -d }
            if e.phase.contains(.began) {
                rawScrollOffset = pageOffset
                lastScrollDelta = 0
            }
            if e.phase.contains(.began) || e.phase.contains(.changed) {
                rawScrollOffset += d
                lastScrollDelta = d
                pageOffset = rubberBand(rawScrollOffset)
            }
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
                finishSwipe(predicted: pageOffset + lastScrollDelta * 14, width: width)
                rawScrollOffset = 0
            }
            return true
        }

        // Mouse wheel: one notch = one page.
        var d = abs(dy) >= abs(dx) ? dy : dx
        if e.isDirectionInvertedFromDevice { d = -d }
        wheelAccum += d
        if abs(wheelAccum) >= 0.5, Date().timeIntervalSince(lastWheelFlip) > 0.35 {
            changePage(wheelAccum < 0 ? 1 : -1)
            lastWheelFlip = Date()
            wheelAccum = 0
        }
        return true
    }

    /// Holding ⌥ makes icons jiggle, like Launchpad.
    func handleFlags(_ e: NSEvent) {
        guard controller?.isVisible == true, drag == nil, searchText.isEmpty, !folderNameEditing else { return }
        let opt = e.modifierFlags.contains(.option)
        if opt && !isEditing {
            optionEditing = true
            withAnimation(.easeInOut(duration: 0.15)) { isEditing = true }
        } else if !opt && optionEditing {
            optionEditing = false
            withAnimation(.easeInOut(duration: 0.15)) { isEditing = false }
        }
    }
}
