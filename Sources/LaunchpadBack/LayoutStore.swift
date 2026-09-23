import Foundation

struct SavedItem: Codable {
    var type: String            // "app" | "folder"
    var path: String?
    var id: String?
    var name: String?
    var apps: [String]?
}

struct SavedLayout: Codable {
    static let currentVersion = 2   // bump to rebuild the default layout after default-order changes
    var version = SavedLayout.currentVersion
    var pages: [[SavedItem]]
}

enum LayoutStore {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LaunchpadClassic/layout.json")
    }

    static func load() -> SavedLayout? {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(SavedLayout.self, from: data),
              saved.version >= SavedLayout.currentVersion else { return nil }
        return saved
    }

    static func save(_ pages: [[LPItem]]) {
        let saved = SavedLayout(pages: pages.map { page in
            page.map { item in
                switch item {
                case .app(let a):
                    return SavedItem(type: "app", path: a.id)
                case .folder(let f):
                    return SavedItem(type: "folder", id: f.id, name: f.name, apps: f.apps.map(\.id))
                }
            }
        })
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            try enc.encode(saved).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("LaunchpadClassic: save failed \(error)")
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Building

    static func build(apps: [AppEntry], saved: SavedLayout?, capacity: Int) -> [[LPItem]] {
        guard let saved else { return defaultLayout(apps: apps, capacity: capacity) }
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pages: [[LPItem]] = saved.pages.map { page in
            page.compactMap { s -> LPItem? in
                if s.type == "folder" {
                    let fapps = (s.apps ?? []).compactMap { byID[$0] }
                    return .folder(FolderEntry(id: s.id ?? UUID().uuidString,
                                               name: s.name ?? L10n.t("未命名文件夹", "Untitled Folder"),
                                               apps: fapps))
                }
                if let p = s.path, let a = byID[p] { return .app(a) }
                return nil
            }
        }
        return merge(pages: pages, apps: apps, capacity: capacity)
    }

    /// Syncs an existing layout with a fresh scan: drops removed apps, refreshes metadata,
    /// appends newly installed apps at the end (like Launchpad does).
    static func merge(pages: [[LPItem]], apps: [AppEntry], capacity: Int) -> [[LPItem]] {
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [[LPItem]] = []
        for page in pages {
            var newPage: [LPItem] = []
            for item in page {
                switch item {
                case .app(let a):
                    guard let n = byID[a.id], !seen.contains(a.id) else { continue }
                    seen.insert(a.id)
                    newPage.append(.app(n))
                case .folder(var f):
                    var fapps: [AppEntry] = []
                    for a in f.apps {
                        guard let n = byID[a.id], !seen.contains(a.id) else { continue }
                        seen.insert(a.id)
                        fapps.append(n)
                    }
                    f.apps = fapps
                    if let norm = normalizeFolder(f) { newPage.append(norm) }
                }
            }
            out.append(newPage)
        }
        let newApps = apps.filter { !seen.contains($0.id) }
        if !newApps.isEmpty {
            if out.isEmpty { out = [[]] }
            out[out.count - 1].append(contentsOf: newApps.map { LPItem.app($0) })
        }
        return reflow(out, capacity: capacity)
    }

    static func normalizeFolder(_ f: FolderEntry) -> LPItem? {
        // A folder left with a single app dissolves into that app (empty folders disappear).
        if f.apps.isEmpty { return nil }
        if f.apps.count == 1 { return .app(f.apps[0]) }
        return .folder(f)
    }

    /// Pushes overflow to the next page (inserted at its front) and drops empty pages.
    static func reflow(_ pages: [[LPItem]], capacity: Int) -> [[LPItem]] {
        let cap = max(1, capacity)
        var result: [[LPItem]] = []
        var carry: [LPItem] = []
        for page in pages {
            var p = carry + page
            carry = []
            if p.count > cap {
                carry = Array(p[cap...])
                p = Array(p[..<cap])
            }
            if !p.isEmpty { result.append(p) }
        }
        while !carry.isEmpty {
            result.append(Array(carry.prefix(cap)))
            carry = Array(carry.dropFirst(cap))
        }
        return result.isEmpty ? [[]] : result
    }

    static func defaultLayout(apps: [AppEntry], capacity: Int) -> [[LPItem]] {
        var remaining = apps
        var items: [LPItem] = []
        for bid in AppleDefaults.order {
            if let i = remaining.firstIndex(where: { $0.bundleID == bid }) {
                items.append(.app(remaining.remove(at: i)))
            }
        }
        func isOther(_ a: AppEntry) -> Bool {
            a.id.hasPrefix("/System/Applications/Utilities/")
                || a.id.hasPrefix("/Applications/Utilities/")
                || AppleDefaults.other.contains(a.bundleID ?? "")
        }
        func isGame(_ a: AppEntry) -> Bool { AppleDefaults.games.contains(a.bundleID ?? "") }
        let others = remaining.filter { isOther($0) && !isGame($0) }
        let games = remaining.filter { isGame($0) }
        let rest = remaining.filter { !isOther($0) && !isGame($0) }
        let system = rest.filter { $0.id.hasPrefix("/System/Applications/") }
        let third = rest.filter { !$0.id.hasPrefix("/System/Applications/") }

        if !others.isEmpty {
            items.append(.folder(FolderEntry(id: UUID().uuidString, name: L10n.t("其他", "Other"), apps: others)))
        }
        if !games.isEmpty {
            items.append(.folder(FolderEntry(id: UUID().uuidString, name: L10n.t("游戏", "Games"), apps: games)))
        }
        items += system.map { .app($0) }
        items += third.map { .app($0) }

        var pages: [[LPItem]] = []
        var i = 0
        let cap = max(1, capacity)
        while i < items.count {
            pages.append(Array(items[i..<min(items.count, i + cap)]))
            i += cap
        }
        return pages.isEmpty ? [[]] : pages
    }
}
