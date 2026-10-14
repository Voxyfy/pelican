import Citadel
import Foundation
import NIOCore
import NIOFoundationCompat

/// File transfer over the pane's existing SFTP connection.
///
/// SFTP answers every 32 KB chunk separately, so sending one chunk at a time is
/// bound by latency. Both directions keep several chunks in flight at once.
extension SFTPFileSource {
    private static let chunkSize = 32_000
    private static let window = 16

    /// Everything under `path` (files and folders), depth first, for folder downloads.
    func walk(_ path: String) async throws -> [FileItem] {
        var result: [FileItem] = []
        for item in try await list(path) {
            result.append(item)
            if item.isDirectory { result += try await walk(item.path) }
        }
        return result
    }

    /// Creates the folder unless it's already there.
    func makeDirectory(_ path: String) async throws {
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            let attributes = try? await sftp.getAttributes(at: path)
            guard let mode = attributes?.permissions, mode & 0o170000 == 0o040000 else { throw error }
        }
    }

    var deletesPermanently: Bool { true }
    var copiesInPlace: Bool { false }

    func createFolder(at path: String) async throws {
        try await sftp.createDirectory(atPath: path)
    }

    func move(_ path: String, to newPath: String) async throws {
        try await sftp.rename(at: path, to: newPath)
    }

    func delete(_ item: FileItem) async throws {
        try await remove(item.path, isDirectory: item.isDirectory)
    }

    /// SFTP has no server-side copy; the transfer queue copies through this Mac instead.
    func copy(_ item: FileItem, to newPath: String) async throws {
        throw CocoaError(.featureUnsupported)
    }

    /// Deletes a file, or a folder and everything in it.
    func remove(_ path: String, isDirectory: Bool) async throws {
        guard isDirectory else { return try await sftp.remove(at: path) }
        for item in try await list(path) {
            try await remove(item.path, isDirectory: item.isDirectory)
        }
        try await sftp.rmdir(at: path)
    }

    func upload(from local: URL, to remotePath: String,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        let file = Unchecked(try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate]))
        do {
            try await withThrowingTaskGroup(of: Int.self) { group in
                var offset: UInt64 = 0
                var inFlight = 0
                while true {
                    try Task.checkCancellation()
                    guard let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty else { break }
                    let at = offset
                    offset += UInt64(data.count)
                    group.addTask {
                        try await file.value.write(ByteBuffer(data: data), at: at)
                        return data.count
                    }
                    inFlight += 1
                    if inFlight == Self.window, let written = try await group.next() {
                        progress(Int64(written))
                        inFlight -= 1
                    }
                }
                for try await written in group { progress(Int64(written)) }
            }
        } catch {
            try? await file.value.close()
            throw error
        }
        try await file.value.close()
    }

    func download(from remotePath: String, size: Int64, to local: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        let file = Unchecked(try await sftp.openFile(filePath: remotePath, flags: .read))
        FileManager.default.createFile(atPath: local.path(percentEncoded: false), contents: nil)
        let output = try FileHandle(forWritingTo: local)
        defer { try? output.close() }
        do {
            try await withThrowingTaskGroup(of: (UInt64, UInt32, ByteBuffer).self) { group in
                // Offsets still to request; a short read puts its remainder back.
                var pending: [(UInt64, UInt32)] = stride(from: 0, to: max(size, 0), by: Self.chunkSize).map {
                    (UInt64($0), UInt32(min(Int64(Self.chunkSize), size - $0)))
                }
                pending.reverse()
                var inFlight = 0
                func fill() {
                    while inFlight < Self.window, let (offset, length) = pending.popLast() {
                        group.addTask { (offset, length, try await file.value.read(from: offset, length: length)) }
                        inFlight += 1
                    }
                }
                fill()
                while let (offset, length, buffer) = try await group.next() {
                    inFlight -= 1
                    try Task.checkCancellation()
                    let count = buffer.readableBytes
                    if count > 0 {
                        try output.seek(toOffset: offset)
                        output.write(Data(buffer: buffer))
                        progress(Int64(count))
                    }
                    if count > 0, count < Int(length) {
                        pending.append((offset + UInt64(count), length - UInt32(count)))
                    }
                    fill()
                }
            }
            // The listing's size can be stale; pick up anything written since.
            var offset = UInt64(max(size, 0))
            while true {
                try Task.checkCancellation()
                let buffer = try await file.value.read(from: offset, length: UInt32(Self.chunkSize))
                if buffer.readableBytes == 0 { break }
                try output.seek(toOffset: offset)
                output.write(Data(buffer: buffer))
                offset += UInt64(buffer.readableBytes)
                progress(Int64(buffer.readableBytes))
            }
        } catch {
            try? await file.value.close()
            throw error
        }
        try await file.value.close()
    }
}

/// Citadel's SFTPFile isn't marked Sendable, but its requests are safe to issue concurrently.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
