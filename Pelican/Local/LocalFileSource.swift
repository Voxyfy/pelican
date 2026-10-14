import Foundation

/// Lists files inside a folder the user granted access to.
struct LocalFileSource: FileSource {
    let root: URL

    var displayName: String { root.lastPathComponent }
    var rootPath: String { root.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/") }
    var startPath: String { rootPath }

    var shortcuts: [PaneShortcut] {
        var result = [PaneShortcut(title: displayName, symbol: "house", path: rootPath)]
        for (folder, symbol) in [("Downloads", "arrow.down.circle"), ("Desktop", "menubar.dock.rectangle")] {
            let url = root.appending(path: folder, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                let title = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
                result.append(PaneShortcut(title: title, symbol: symbol, path: url.path(percentEncoded: false)))
            }
        }
        return result
    }

    var deletesPermanently: Bool { false }
    var copiesInPlace: Bool { true }

    func createFolder(at path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    func move(_ path: String, to newPath: String) async throws {
        try FileManager.default.moveItem(atPath: path, toPath: newPath)
    }

    /// Goes to the Trash, like Finder, so it can be put back.
    func delete(_ item: FileItem) async throws {
        try FileManager.default.trashItem(at: URL(filePath: item.path), resultingItemURL: nil)
    }

    func copy(_ item: FileItem, to newPath: String) async throws {
        try FileManager.default.copyItem(atPath: item.path, toPath: newPath)
    }

    func list(_ path: String) async throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL,
            includingPropertiesForKeys: keys
        )
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            return FileItem(
                name: url.lastPathComponent,
                path: url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/"),
                isDirectory: isDirectory,
                size: isDirectory ? nil : values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate
            )
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        count > 1 && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
