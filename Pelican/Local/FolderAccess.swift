import AppKit

/// The sandbox only lets us read folders the user picked, so we remember
/// that choice as a security-scoped bookmark and reopen it on every launch.
@MainActor
enum FolderAccess {
    private static let key = "localRootBookmark"

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if stale { save(url) }
        return url
    }

    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Allow Access")
        panel.message = String(localized: "Choose the folder Pelican can browse. Your home folder works best.")
        panel.directoryURL = URL(filePath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url,
              url.startAccessingSecurityScopedResource() else { return nil }
        save(url)
        return url
    }

    private static func save(_ url: URL) {
        let data = try? url.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
    }
}
