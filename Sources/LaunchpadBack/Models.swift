import AppKit

// MARK: - Localization

enum L10n {
    static let isChinese: Bool = {
        let lang = Locale.preferredLanguages.first ?? ""
        return lang.hasPrefix("zh")
    }()

    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
}

// MARK: - Core data

struct AppEntry: Identifiable, Hashable, Sendable {
    let id: String          // bundle path, stable key for persistence
    let url: URL
    let name: String        // localized display name
    let bundleID: String?
    let category: String?   // LSApplicationCategoryType
    let isAppStore: Bool    // has _MASReceipt → can be deleted from Launchpad
    let searchKeys: [String]
}

struct FolderEntry: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var apps: [AppEntry]
}

enum LPItem: Identifiable, Hashable, Sendable {
    case app(AppEntry)
    case folder(FolderEntry)

    var id: String {
        switch self {
        case .app(let a): return a.id
        case .folder(let f): return f.id
        }
    }

    var name: String {
        switch self {
        case .app(let a): return a.name
        case .folder(let f): return f.name
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    var apps: [AppEntry] {
        switch self {
        case .app(let a): return [a]
        case .folder(let f): return f.apps
        }
    }
}

/// Which grid is currently interactive.
enum Ctx: Equatable {
    case main
    case search
    case folder(String)
}

struct PlacedItem: Identifiable {
    let item: LPItem
    let slot: Int
    var id: String { item.id }
}

struct DragState {
    var item: LPItem
    var location: CGPoint
    var grabOffset: CGSize
    var fromFolderID: String?
    var targetIndex: Int
    var mergeTargetID: String?
    var dropping = false
    /// Dropped onto another icon: shrink into the folder instead of landing in a slot.
    var mergingIn = false
}

enum HitTarget {
    case item(Ctx, index: Int, item: LPItem)
    case delete(AppEntry)
    case empty
    case outsideFolder
    case folderEmpty
}

struct PressState {
    enum Mode { case pending, longPressed, swipe, dragging }
    var hit: HitTarget
    var mode: Mode
}

// MARK: - Icon cache

final class IconCache: @unchecked Sendable {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func icon(for app: AppEntry) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        if let img = cache[app.id] { return img }
        // Resolve symlinks (e.g. Safari on macOS 26+) so no alias arrow is drawn on the icon.
        let img = NSWorkspace.shared.icon(forFile: app.url.resolvingSymlinksInPath().path)
        img.size = NSSize(width: 256, height: 256)
        cache[app.id] = img
        return img
    }

    func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

// MARK: - App Store categories → folder names (same as Launchpad's auto naming)

enum Categories {
    static func folderName(_ apps: [AppEntry]) -> String {
        for a in apps {
            if let c = a.category, let n = name(for: c) { return n }
        }
        return L10n.t("未命名文件夹", "Untitled Folder")
    }

    static func name(for raw: String) -> String? {
        let key = raw.replacingOccurrences(of: "public.app-category.", with: "")
        if key.hasSuffix("games") { return L10n.t("游戏", "Games") }
        let map: [String: (String, String)] = [
            "business": ("商务", "Business"),
            "developer-tools": ("开发者工具", "Developer Tools"),
            "education": ("教育", "Education"),
            "entertainment": ("娱乐", "Entertainment"),
            "finance": ("财务", "Finance"),
            "graphics-design": ("图形与设计", "Graphics & Design"),
            "healthcare-fitness": ("健康健美", "Health & Fitness"),
            "lifestyle": ("生活", "Lifestyle"),
            "medical": ("医疗", "Medical"),
            "music": ("音乐", "Music"),
            "news": ("新闻", "News"),
            "photography": ("摄影与录像", "Photo & Video"),
            "video": ("摄影与录像", "Photo & Video"),
            "productivity": ("效率", "Productivity"),
            "reference": ("参考资料", "Reference"),
            "social-networking": ("社交", "Social Networking"),
            "sports": ("体育", "Sports"),
            "travel": ("旅游", "Travel"),
            "utilities": ("工具", "Utilities"),
            "weather": ("天气", "Weather"),
        ]
        guard let v = map[key] else { return nil }
        return L10n.t(v.0, v.1)
    }
}

// MARK: - Default order (approximates macOS 15 fresh-install Launchpad)

enum AppleDefaults {
    /// Page-one order of a fresh macOS 15 Launchpad (from Apple's own screenshot).
    static let order: [String] = [
        "com.apple.AppStore", "com.apple.Safari", "com.apple.mail", "com.apple.AddressBook",
        "com.apple.iCal", "com.apple.reminders", "com.apple.Notes", "com.apple.FaceTime",
        "com.apple.MobileSMS", "com.apple.Maps", "com.apple.findmy", "com.apple.PhotoBooth",
        "com.apple.Photos", "com.apple.Music", "com.apple.podcasts", "com.apple.TV",
        "com.apple.VoiceMemos", "com.apple.iWork.Keynote", "com.apple.iWork.Numbers", "com.apple.iWork.Pages",
        "com.apple.weather", "com.apple.news", "com.apple.stocks", "com.apple.iBooksX",
        "com.apple.clock", "com.apple.calculator", "com.apple.freeform", "com.apple.Home",
        "com.apple.Siri", "com.apple.ScreenContinuity", "com.apple.Passwords", "com.apple.systempreferences",
    ]

    /// Apps that live in the "Other" folder besides everything in Utilities.
    static let other: Set<String> = [
        "com.apple.shortcuts", "com.apple.QuickTimePlayerX", "com.apple.TextEdit", "com.apple.FontBook",
        "com.apple.backup.launcher", "com.apple.exposelauncher", "com.apple.Stickies",
        "com.apple.Image_Capture", "com.apple.Automator", "com.apple.grapher",
    ]

    /// Apps that live in the "Games" folder.
    static let games: Set<String> = ["com.apple.Chess", "com.apple.games"]

    /// Never shown.
    static let excluded: Set<String> = [
        "com.apple.launchpad.launcher",
    ]
}
