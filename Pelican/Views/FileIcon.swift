import AppKit
import UniformTypeIdentifiers

/// Finder icons: the real file's icon on this Mac, the icon for its type on a server.
@MainActor
enum FileIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for item: FileItem, local: Bool) -> NSImage {
        let key = local ? item.path : (item.isDirectory ? "/folder" : "." + item.fileExtension)
        if let cached = cache[key] { return cached }
        let icon: NSImage
        if local {
            icon = NSWorkspace.shared.icon(forFile: item.path)
        } else if item.isDirectory {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else {
            icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: item.fileExtension) ?? .data)
        }
        if cache.count > 2_000 { cache.removeAll() }
        cache[key] = icon
        return icon
    }
}
