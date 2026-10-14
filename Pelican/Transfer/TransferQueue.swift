import Foundation
import Observation

/// One item the user dropped: a file, or a folder with everything inside it.
@MainActor @Observable
final class Transfer: Identifiable {
    enum Direction { case upload, download, copy }
    enum State: Equatable {
        case waiting, preparing, running, done
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: true
            default: false
            }
        }
    }

    let id = UUID()
    let direction: Direction
    let name: String
    let destination: String
    fileprivate(set) var state = State.waiting
    fileprivate(set) var totalBytes: Int64 = 0
    fileprivate(set) var doneBytes: Int64 = 0
    fileprivate let work: (Transfer) async throws -> Void
    fileprivate let onFinish: () -> Void
    fileprivate var task: Task<Void, Never>?

    var fraction: Double { totalBytes > 0 ? min(Double(doneBytes) / Double(totalBytes), 1) : 0 }

    fileprivate init(direction: Direction, name: String, destination: String,
                     onFinish: @escaping () -> Void, work: @escaping (Transfer) async throws -> Void) {
        self.direction = direction
        self.name = name
        self.destination = destination
        self.onFinish = onFinish
        self.work = work
    }

    fileprivate func setTotal(_ bytes: Int64) {
        totalBytes = bytes
        state = .running
    }

    /// Progress reports arrive from transfer tasks; hop to the main actor to count them.
    fileprivate nonisolated func reporter() -> @Sendable (Int64) -> Void {
        { bytes in Task { @MainActor in self.doneBytes += bytes } }
    }
}

/// Runs transfers one at a time, in the order they were added.
@MainActor @Observable
final class TransferQueue {
    private(set) var transfers: [Transfer] = []

    var activeCount: Int { transfers.filter { !$0.state.isFinished }.count }

    /// Progress across everything not yet finished, for the toolbar ring.
    var activeFraction: Double {
        let active = transfers.filter { !$0.state.isFinished }
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return 0 }
        return min(Double(active.reduce(Int64(0)) { $0 + $1.doneBytes }) / Double(total), 1)
    }
    var hasFinished: Bool { transfers.contains { $0.state.isFinished } }

    func upload(_ items: [FileItem], to folder: String, via server: any RemoteSource,
                onFinish: @escaping () -> Void) {
        for item in items {
            let target = (folder as NSString).appendingPathComponent(item.name)
            add(Transfer(direction: .upload, name: item.name, destination: folder, onFinish: onFinish) { transfer in
                let source = URL(filePath: item.path, directoryHint: item.isDirectory ? .isDirectory : .notDirectory)
                transfer.setTotal(try LocalPlan(root: source, isDirectory: item.isDirectory).totalBytes)
                try await Self.send(source, isDirectory: item.isDirectory, to: target, via: server,
                                    report: transfer.reporter())
            })
        }
    }

    func download(_ items: [FileItem], to folder: String, via server: any RemoteSource,
                  onFinish: @escaping () -> Void) {
        for item in items {
            let target = URL(filePath: folder, directoryHint: .isDirectory).appending(path: item.name)
            add(Transfer(direction: .download, name: item.name, destination: folder, onFinish: onFinish) { transfer in
                let contents = item.isDirectory ? try await server.walk(item.path) : []
                transfer.setTotal(Self.size(of: item, contents: contents))
                try await Self.fetch(item, contents: contents, to: target, via: server, report: transfer.reporter())
            })
        }
    }

    /// Copies on the same server by downloading to a temporary folder and uploading again.
    func copy(_ items: [(item: FileItem, name: String)], to folder: String, via server: any RemoteSource,
              onFinish: @escaping () -> Void) {
        for (item, name) in items {
            let target = (folder as NSString).appendingPathComponent(name)
            add(Transfer(direction: .copy, name: name, destination: folder, onFinish: onFinish) { transfer in
                let contents = item.isDirectory ? try await server.walk(item.path) : []
                let size = Self.size(of: item, contents: contents)
                transfer.setTotal(size * 2) // down, then up
                let report = transfer.reporter()
                let scratch = FileManager.default.temporaryDirectory.appending(path: "pelican-copy-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: scratch) }
                let local = scratch.appending(path: item.name)
                try await Self.fetch(item, contents: contents, to: local, via: server, report: report)
                try await Self.send(local, isDirectory: item.isDirectory, to: target, via: server, report: report)
            })
        }
    }

    private static func size(of item: FileItem, contents: [FileItem]) -> Int64 {
        item.isDirectory ? contents.reduce(0) { $0 + ($1.size ?? 0) } : (item.size ?? 0)
    }

    /// Downloads a file, or a folder whose `contents` came from `walk`.
    private static func fetch(_ item: FileItem, contents: [FileItem], to target: URL, via server: any RemoteSource,
                              report: @escaping @Sendable (Int64) -> Void) async throws {
        guard item.isDirectory else {
            return try await server.download(from: item.path, size: item.size ?? 0, to: target, progress: report)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let prefix = item.path.hasSuffix("/") ? item.path : item.path + "/"
        for entry in contents {
            try Task.checkCancellation()
            let local = target.appending(path: String(entry.path.dropFirst(prefix.count)))
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            } else {
                try await server.download(from: entry.path, size: entry.size ?? 0, to: local, progress: report)
            }
        }
    }

    /// Uploads a local file or folder to `target`, creating folders as needed.
    private static func send(_ source: URL, isDirectory: Bool, to target: String, via server: any RemoteSource,
                             report: @escaping @Sendable (Int64) -> Void) async throws {
        let plan = try LocalPlan(root: source, isDirectory: isDirectory)
        if isDirectory { try await server.makeDirectory(target) }
        for folder in plan.folders {
            try Task.checkCancellation()
            try await server.makeDirectory((target as NSString).appendingPathComponent(folder))
        }
        for file in plan.files {
            try Task.checkCancellation()
            let remote = file.relative.isEmpty ? target : (target as NSString).appendingPathComponent(file.relative)
            try await server.upload(from: file.url, to: remote, progress: report)
        }
    }

    func cancel(_ transfer: Transfer) {
        if transfer.state == .waiting {
            transfer.state = .cancelled
            ActivityLog.shared.info(String(localized: "Cancelled \(transfer.name)."))
        } else {
            transfer.task?.cancel()
        }
    }

    func clearFinished() {
        transfers.removeAll { $0.state.isFinished }
    }

    private func add(_ transfer: Transfer) {
        transfers.append(transfer)
        startNext()
    }

    private func startNext() {
        guard !transfers.contains(where: { $0.state == .preparing || $0.state == .running }),
              let next = transfers.first(where: { $0.state == .waiting }) else { return }
        next.state = .preparing
        next.task = Task {
            let log = ActivityLog.shared
            do {
                try await next.work(next)
                try Task.checkCancellation()
                next.state = .done
                let size = next.totalBytes.formatted(.byteCount(style: .file))
                switch next.direction {
                case .upload: log.success(String(localized: "Uploaded \(next.name) (\(size)) to \(next.destination)."))
                case .download: log.success(String(localized: "Downloaded \(next.name) (\(size)) to \(next.destination)."))
                case .copy: log.success(String(localized: "Copied \(next.name) to \(next.destination)."))
                }
            } catch is CancellationError {
                next.state = .cancelled
                log.info(String(localized: "Cancelled \(next.name)."))
            } catch {
                let message = FriendlyError.transferMessage(for: error)
                next.state = .failed(message)
                log.error(String(localized: "\(next.name) failed: \(message)"))
            }
            next.onFinish()
            startNext()
        }
    }
}

/// The files and folders inside a local upload, with sizes, gathered before sending.
private struct LocalPlan {
    struct File { let url: URL; let relative: String }
    var files: [File] = []
    var folders: [String] = []
    var totalBytes: Int64 = 0

    init(root: URL, isDirectory: Bool) throws {
        guard isDirectory else {
            files = [File(url: root, relative: "")]
            totalBytes = Int64(try root.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            return
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        let base = root.standardizedFileURL.path(percentEncoded: false)
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: keys)
            let relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if values.isDirectory == true {
                folders.append(relative)
            } else {
                files.append(File(url: url, relative: relative))
                totalBytes += Int64(values.fileSize ?? 0)
            }
        }
    }
}
