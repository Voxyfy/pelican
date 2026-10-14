import Foundation

/// One entry in a directory listing, local or remote.
struct FileItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?

    var isHidden: Bool { name.hasPrefix(".") }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    // Non-optional keys so the table can sort by them.
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modified ?? .distantPast }
}

extension FileItem {
    /// A file dragged in from Finder.
    init?(localURL url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        else { return nil }
        let isDirectory = values.isDirectory ?? false
        self.init(name: url.lastPathComponent,
                  path: url.standardizedFileURL.path(percentEncoded: false),
                  isDirectory: isDirectory,
                  size: isDirectory ? nil : values.fileSize.map(Int64.init),
                  modified: values.contentModificationDate)
    }
}
