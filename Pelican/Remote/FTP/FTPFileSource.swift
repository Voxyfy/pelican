import Foundation

/// Browses a server over FTP or FTPS. One control connection lists and edits files; a second,
/// opened on first use, carries transfers, so browsing keeps working during a long upload.
final class FTPFileSource: RemoteSource, @unchecked Sendable {
    let server: Server
    let startPath: String
    let rootPath = "/"
    var displayName: String { server.title }
    var deletesPermanently: Bool { true }
    var copiesInPlace: Bool { false }

    private let browser: FTPClient
    private let lane: TransferLane

    private init(server: Server, browser: FTPClient, lane: TransferLane, startPath: String) {
        self.server = server
        self.browser = browser
        self.lane = lane
        self.startPath = startPath
    }

    static func connect(to server: Server, password: String) async throws -> FTPFileSource {
        let open: @Sendable () async throws -> FTPClient = {
            try await FTPClient.connect(host: server.host, port: server.port, tls: server.kind == .ftps,
                                        user: server.username, password: password)
        }
        let browser = try await open()
        var start = try await browser.currentDirectory()
        if let requested = server.remotePath?.trimmingCharacters(in: .whitespaces), !requested.isEmpty,
           await browser.isDirectory(requested) {
            start = requested
        }
        return FTPFileSource(server: server, browser: browser, lane: TransferLane(open: open), startPath: start)
    }

    func list(_ path: String) async throws -> [FileItem] {
        try await browser.list(path)
    }

    func createFolder(at path: String) async throws {
        try await browser.makeDirectory(path)
    }

    func makeDirectory(_ path: String) async throws {
        if await browser.isDirectory(path) { return }
        try await browser.makeDirectory(path)
    }

    func move(_ path: String, to newPath: String) async throws {
        try await browser.rename(path, to: newPath)
    }

    func delete(_ item: FileItem) async throws {
        try await remove(item.path, isDirectory: item.isDirectory)
    }

    func remove(_ path: String, isDirectory: Bool) async throws {
        guard isDirectory else { return try await browser.removeFile(path) }
        for item in try await list(path) {
            try await remove(item.path, isDirectory: item.isDirectory)
        }
        try await browser.removeDirectory(path)
    }

    /// FTP has no server-side copy; the transfer queue copies through this Mac instead.
    func copy(_ item: FileItem, to newPath: String) async throws {
        throw CocoaError(.featureUnsupported)
    }

    func upload(from local: URL, to remotePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await lane.run { try await $0.store(from: local, to: remotePath, progress: progress) }
    }

    func download(from remotePath: String, size: Int64, to local: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await lane.run { try await $0.retrieve(remotePath, to: local, progress: progress) }
    }

    func disconnect() async {
        await lane.close()
        await browser.quit()
    }
}

/// The transfer connection: opened when first needed, dropped after an error or a cancel
/// so the next transfer starts from a clean state.
private actor TransferLane {
    private let open: @Sendable () async throws -> FTPClient
    private var client: FTPClient?

    init(open: @escaping @Sendable () async throws -> FTPClient) {
        self.open = open
    }

    func run(_ work: (FTPClient) async throws -> Void) async throws {
        let client: FTPClient
        if let existing = self.client {
            client = existing
        } else {
            client = try await open()
            self.client = client
        }
        do {
            try await work(client)
        } catch {
            self.client = nil
            await client.quit()
            throw error
        }
    }

    func close() async {
        await client?.quit()
        client = nil
    }
}
