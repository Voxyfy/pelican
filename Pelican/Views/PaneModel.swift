import Foundation
import Observation

/// One visible line in a pane: a file plus how deep it sits in expanded folders.
struct PaneRow: Identifiable, Hashable {
    var id: String { item.path }
    let item: FileItem
    let depth: Int
}

/// Navigation state for one pane, independent of where the files live.
@MainActor @Observable
final class PaneModel {
    let id = UUID()
    let source: any FileSource
    private(set) var path: String
    private(set) var error: String?
    private(set) var isLoading = false
    var showHidden = false { didSet { Task { await reload() } } }
    var sortOrder = [KeyPathComparator(\PaneRow.item.name, comparator: .localizedStandard)]

    /// The row whose name is being edited in place.
    var renaming: PaneRow.ID?
    /// Shown as an alert when a rename, move, copy or delete fails.
    var operationError: String?

    private var listings: [String: [FileItem]] = [:]
    private(set) var expanded: Set<String> = []
    private var history: [String] = []

    init(source: any FileSource) {
        self.source = source
        self.path = source.startPath
    }

    var isLocal: Bool { source is LocalFileSource }
    var canGoBack: Bool { !history.isEmpty }
    var canGoUp: Bool { source.parent(of: path) != nil }
    var folderName: String { path == source.rootPath ? source.displayName : (path as NSString).lastPathComponent }

    /// Current folder plus the contents of every expanded subfolder, sorted per level.
    var rows: [PaneRow] {
        var result: [PaneRow] = []
        func add(_ folder: String, depth: Int) {
            let level = (listings[folder] ?? [])
                .filter { showHidden || !$0.isHidden }
                .map { PaneRow(item: $0, depth: depth) }
                .sorted(using: sortOrder)
            for row in level {
                result.append(row)
                if row.item.isDirectory, expanded.contains(row.item.path) {
                    add(row.item.path, depth: depth + 1)
                }
            }
        }
        add(path, depth: 0)
        return result
    }

    /// Names already in `folder`, to spot files a transfer would replace. Empty if it isn't loaded.
    func names(in folder: String) -> Set<String> { Set((listings[folder] ?? []).map(\.name)) }

    /// Where a drop on `row` goes: into the folder itself, or next to the file.
    func dropFolder(for row: PaneRow) -> String {
        row.item.isDirectory ? row.item.path : (row.item.path as NSString).deletingLastPathComponent
    }

    func item(withID id: PaneRow.ID) -> FileItem? {
        listings.values.lazy.flatMap { $0 }.first { $0.path == id }
    }

    func open(_ item: FileItem) async {
        guard item.isDirectory else { return }
        await navigate(to: item.path)
    }

    func navigate(to newPath: String) async {
        guard newPath != path else { return }
        let previous = path
        if await load(newPath) { history.append(previous) }
    }

    func back() async {
        guard let previous = history.popLast() else { return }
        await load(previous)
    }

    func up() async {
        guard let parent = source.parent(of: path) else { return }
        await navigate(to: parent)
    }

    func reload() async { await load(path) }

    /// Re-reads the current folder and every expanded one, after files changed.
    func reloadAll() async {
        await reload()
        for folder in expanded {
            if let listing = try? await source.list(folder) { listings[folder] = listing }
        }
    }

    // MARK: File operations

    /// A name not yet used in `folder`: "name", then "name 2", "name 3"… before the extension.
    func freeName(for name: String, in folder: String, copy: Bool = false) -> String {
        let taken = names(in: folder)
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        if copy, taken.contains(name) { base = String(localized: "\(base) copy") }
        func make(_ suffix: Int) -> String {
            let stem = suffix == 1 ? base : "\(base) \(suffix)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var suffix = 1
        while taken.contains(make(suffix)) { suffix += 1 }
        return make(suffix)
    }

    /// Set when a new folder needs its name up front; the pane shows a name prompt.
    var askingFolderName = false

    /// Creates "untitled folder" and starts renaming it, like Finder, or asks for the name first.
    func newFolder() async {
        if source.namesFolderFirst(in: path) {
            askingFolderName = true
            return
        }
        let folder = path
        let target = (folder as NSString).appendingPathComponent(freeName(for: String(localized: "untitled folder"), in: folder))
        await perform(String(localized: "Created folder \(target).")) {
            try await self.source.createFolder(at: target)
            await self.reload()
            self.renaming = target
        }
    }

    func newFolder(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let target = (path as NSString).appendingPathComponent(name)
        await perform(String(localized: "Created folder \(target).")) {
            try await self.source.createFolder(at: target)
        }
    }

    func rename(_ item: FileItem, to newName: String) async {
        renaming = nil
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        guard !name.contains("/") else {
            operationError = String(localized: "Names can't contain “/”.")
            ActivityLog.shared.error(operationError ?? "")
            return
        }
        let parent = (item.path as NSString).deletingLastPathComponent
        guard !names(in: parent).contains(name) else {
            operationError = String(localized: "“\(name)” already exists. Choose a different name.")
            return
        }
        await perform(String(localized: "Renamed \(item.name) to \(name).")) {
            try await self.source.move(item.path, to: (parent as NSString).appendingPathComponent(name))
        }
    }

    /// Moves items into `folder`, skipping ones already there or folders dropped into themselves.
    func move(_ items: [FileItem], to folder: String) async {
        let movable = items.filter { item in
            (item.path as NSString).deletingLastPathComponent != folder
                && folder != item.path && !folder.hasPrefix(item.path + "/")
        }
        guard !movable.isEmpty else { return }
        if let clash = movable.first(where: { names(in: folder).contains($0.name) }) {
            operationError = String(localized: "“\(clash.name)” already exists. Choose a different name.")
            return
        }
        await perform(String(localized: "Moved \(Self.list(movable)) to \(folder).")) {
            for item in movable {
                try await self.source.move(item.path, to: (folder as NSString).appendingPathComponent(item.name))
            }
        }
    }

    /// Copies on this Mac. Servers copy through the transfer queue instead.
    func copyInPlace(_ items: [FileItem], to folder: String) async {
        await perform(String(localized: "Copied \(Self.list(items)) to \(folder).")) {
            for item in items where folder != item.path && !folder.hasPrefix(item.path + "/") {
                let name = self.freeName(for: item.name, in: folder, copy: true)
                try await self.source.copy(item, to: (folder as NSString).appendingPathComponent(name))
            }
        }
    }

    func delete(_ items: [FileItem]) async {
        let done = source.deletesPermanently
            ? String(localized: "Deleted \(Self.list(items)).")
            : String(localized: "Moved \(Self.list(items)) to the Trash.")
        await perform(done) {
            for item in items { try await self.source.delete(item) }
        }
    }

    private func perform(_ done: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            ActivityLog.shared.success(done)
        } catch {
            operationError = FriendlyError.transferMessage(for: error)
            ActivityLog.shared.error(operationError ?? "")
        }
        await reloadAll()
    }

    /// "a.txt", "a.txt, b.txt" or "a.txt and 4 more", for log lines.
    private static func list(_ items: [FileItem]) -> String {
        switch items.count {
        case 0: ""
        case 1, 2: items.map(\.name).joined(separator: ", ")
        default: String(localized: "\(items[0].name) and \(items.count - 1) more")
        }
    }

    /// Re-reads one folder after a transfer: the current one, or an expanded subfolder.
    func refresh(_ folder: String) async {
        if folder == path { return await reload() }
        guard expanded.contains(folder), let listing = try? await source.list(folder) else { return }
        listings[folder] = listing
    }

    func toggle(_ item: FileItem) async {
        if expanded.remove(item.path) != nil { return }
        do {
            listings[item.path] = try await source.list(item.path)
            expanded.insert(item.path)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    private func load(_ newPath: String) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let listing = try await source.list(newPath)
            if newPath != path {
                listings = [:]
                expanded = []
            }
            listings[newPath] = listing
            path = newPath
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
