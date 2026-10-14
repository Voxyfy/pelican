import Foundation

/// Anything a pane can browse: this Mac, an SFTP server, an S3 bucket.
protocol FileSource: Sendable {
    var displayName: String { get }
    /// The topmost folder; "up" stops here.
    var rootPath: String { get }
    /// Where the pane opens, e.g. the user's home folder on a server.
    var startPath: String { get }
    /// Quick jumps shown above the list, like Home, Downloads and Desktop.
    var shortcuts: [PaneShortcut] { get }
    /// True on servers, where nothing goes to a Trash and deleting can't be undone.
    var deletesPermanently: Bool { get }
    /// True when copying happens on the source itself; servers copy by downloading and re-uploading.
    var copiesInPlace: Bool { get }

    func list(_ path: String) async throws -> [FileItem]
    func createFolder(at path: String) async throws
    /// Renames or moves; `newPath` is the full destination path.
    func move(_ path: String, to newPath: String) async throws
    func delete(_ item: FileItem) async throws
    func copy(_ item: FileItem, to newPath: String) async throws
}

struct PaneShortcut: Hashable, Sendable {
    let title: String
    let symbol: String
    let path: String
}

extension FileSource {
    var shortcuts: [PaneShortcut] { [] }

    /// Folders from the root down to `path`, for the path menu.
    func ancestors(of path: String) -> [String] {
        var chain = [path]
        var current = path
        while let parent = parent(of: current) {
            chain.append(parent)
            current = parent
        }
        return chain
    }

    func parent(of path: String) -> String? {
        guard path != rootPath else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
