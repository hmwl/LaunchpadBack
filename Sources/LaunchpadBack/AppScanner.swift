import AppKit

enum AppScanner {
    static func scan() -> [AppEntry] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/System/Applications", home + "/Applications"]
        let ownID = Bundle.main.bundleIdentifier

        var seenPaths = Set<String>()
        var seenBundles = Set<String>()
        var out: [AppEntry] = []

        func add(_ path: String) {
            let url = URL(fileURLWithPath: path)
            let resolved = url.resolvingSymlinksInPath().path
            if seenPaths.contains(resolved) { return }
            seenPaths.insert(resolved)

            // Read Info.plist directly (Bundle(url:) caches forever and goes stale after updates).
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
            let bid = info?["CFBundleIdentifier"] as? String
            if let bid {
                if bid == ownID || AppleDefaults.excluded.contains(bid) || seenBundles.contains(bid) { return }
                seenBundles.insert(bid)
            }

            var name = fm.displayName(atPath: path)
            if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
            let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let category = info?["LSApplicationCategoryType"] as? String
            let mas = fm.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")

            out.append(AppEntry(
                id: path,
                url: url,
                name: name,
                bundleID: bid,
                category: category,
                isAppStore: mas && path.hasPrefix("/Applications/"),
                searchKeys: searchKeys(name: name, fileName: fileName)
            ))
        }

        func visit(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names.sorted() where !n.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(n)
                if n.lowercased().hasSuffix(".app") {
                    add(path)
                } else if depth < 2, (n as NSString).pathExtension.isEmpty {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        visit(path, depth: depth + 1)
                    }
                }
            }
        }

        for r in roots { visit(r, depth: 0) }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func searchKeys(name: String, fileName: String) -> [String] {
        var keys = [name.lowercased(), fileName.lowercased()]
        if let py = pinyin(name) {
            keys.append(py.full)
            keys.append(py.initials)
        }
        return keys
    }

    /// "微信" → ("weixin", "wx")
    static func pinyin(_ s: String) -> (full: String, initials: String)? {
        let hasCJK = s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        guard hasCJK else { return nil }
        let m = NSMutableString(string: s)
        CFStringTransform(m as CFMutableString, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m as CFMutableString, nil, kCFStringTransformStripDiacritics, false)
        let parts = (m as String).lowercased().split(separator: " ")
        let full = parts.joined()
        let initials = parts.compactMap { $0.first.map(String.init) }.joined()
        return (full, initials)
    }
}
