import Foundation

/// Browses a WebDAV server: Nextcloud, ownCloud, Synology, Apache mod_dav, a hosting panel's
/// web disk. Every call is one HTTP request, so browsing and transfers share one session.
final class WebDAVFileSource: RemoteSource, @unchecked Sendable {
    let server: Server
    let startPath: String
    let rootPath = "/"
    var displayName: String { server.title }
    var deletesPermanently: Bool { true }
    /// WebDAV copies on the server with COPY.
    var copiesInPlace: Bool { true }

    private let client: WebDAVClient

    private init(server: Server, client: WebDAVClient, startPath: String) {
        self.server = server
        self.client = client
        self.startPath = startPath
    }

    static func connect(to server: Server, password: String) async throws -> WebDAVFileSource {
        let client = WebDAVClient(base: try WebDAVClient.baseURL(for: server), user: server.username, password: password)
        var start = server.remotePath?.trimmingCharacters(in: .whitespaces) ?? ""
        if !start.hasPrefix("/") { start = "/" + start }
        while start.count > 1, start.hasSuffix("/") { start.removeLast() }
        try await client.checkFolder(start)
        return WebDAVFileSource(server: server, client: client, startPath: start)
    }

    func list(_ path: String) async throws -> [FileItem] {
        try await client.list(path).map {
            FileItem(name: $0.name, path: (path as NSString).appendingPathComponent($0.name),
                     isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified)
        }
    }

    func createFolder(at path: String) async throws {
        try await client.makeCollection(path)
    }

    /// 405 means the folder is already there, which is fine when uploading into it.
    func makeDirectory(_ path: String) async throws {
        do {
            try await client.makeCollection(path)
        } catch let error as WebDAVError where error.status == 405 {}
    }

    func move(_ path: String, to newPath: String) async throws {
        try await client.move(path, to: newPath)
    }

    func copy(_ item: FileItem, to newPath: String) async throws {
        try await client.copy(item.path, to: newPath, isDirectory: item.isDirectory)
    }

    func delete(_ item: FileItem) async throws {
        try await remove(item.path, isDirectory: item.isDirectory)
    }

    /// DELETE removes a folder with everything in it.
    func remove(_ path: String, isDirectory: Bool) async throws {
        try await client.delete(path, isDirectory: isDirectory)
    }

    func upload(from local: URL, to remotePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await client.upload(from: local, to: remotePath, progress: progress)
    }

    func download(from remotePath: String, size: Int64, to local: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await client.download(remotePath, to: local, progress: progress)
    }

    func disconnect() async {}
}
