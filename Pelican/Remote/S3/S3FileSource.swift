import Foundation

/// Browses S3 or Cloudflare R2. "/" lists buckets; "/bucket/a/b" is the prefix "a/b/" in that
/// bucket. Folders are prefixes, so an empty folder is kept alive by a "name/" marker object.
final class S3FileSource: RemoteSource, @unchecked Sendable {
    let server: Server
    let startPath: String
    let rootPath = "/"
    var displayName: String { server.title }
    var deletesPermanently: Bool { true }
    /// S3 copies on the server, so copying needs no trip through this Mac.
    var copiesInPlace: Bool { true }

    private let client: S3Client

    private init(server: Server, client: S3Client, startPath: String) {
        self.server = server
        self.client = client
        self.startPath = startPath
    }

    static func connect(to server: Server, secret: String) async throws -> S3FileSource {
        let client = S3Client(endpoint: try endpoint(for: server), accessKey: server.username, secretKey: secret,
                              region: server.kind == .r2 ? "auto" : (server.region ?? "us-east-1"))
        var start = server.remotePath?.trimmingCharacters(in: .whitespaces) ?? ""
        if start.isEmpty || start == "/" {
            start = "/"
            _ = try await client.listBuckets()
        } else {
            if !start.hasPrefix("/") { start = "/" + start }
            if start.count > 1, start.hasSuffix("/") { start.removeLast() }
            let (bucket, key) = split(start)
            _ = try await client.list(bucket: bucket, prefix: key.isEmpty ? "" : key + "/", limit: 1)
        }
        return S3FileSource(server: server, client: client, startPath: start)
    }

    /// "s3.amazonaws.com", "abc.r2.cloudflarestorage.com" or "http://127.0.0.1" plus the port.
    static func endpoint(for server: Server) throws -> URL {
        var host = server.host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { host = server.kind == .r2 ? "" : "s3.amazonaws.com" }
        if !host.contains("://") { host = "https://" + host }
        guard var components = URLComponents(string: host), components.host?.isEmpty == false else {
            throw URLError(.badURL)
        }
        let standard = components.scheme == "http" ? 80 : 443
        components.port = server.port == standard || server.port == 0 ? nil : server.port
        components.path = ""
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    // MARK: Paths

    /// "/bucket/a/b" → ("bucket", "a/b"); "/bucket" → ("bucket", "").
    private static func split(_ path: String) -> (bucket: String, key: String) {
        let trimmed = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let bucket = trimmed.first else { return ("", "") }
        return (String(bucket), trimmed.dropFirst().joined(separator: "/"))
    }

    private func join(_ folder: String, _ name: String) -> String {
        (folder as NSString).appendingPathComponent(name)
    }

    // MARK: Listing

    func list(_ path: String) async throws -> [FileItem] {
        let (bucket, key) = Self.split(path)
        guard !bucket.isEmpty else {
            return try await client.listBuckets().map {
                FileItem(name: $0, path: "/" + $0, isDirectory: true, size: nil, modified: nil)
            }
        }
        let prefix = key.isEmpty ? "" : key + "/"
        let listing = try await client.list(bucket: bucket, prefix: prefix)
        let folders = listing.folders.map { folder -> FileItem in
            let name = String(folder.dropFirst(prefix.count).dropLast())
            return FileItem(name: name, path: join(path, name), isDirectory: true, size: nil, modified: nil)
        }
        let files = listing.objects.filter { $0.key != prefix }.map { object -> FileItem in
            let name = String(object.key.dropFirst(prefix.count))
            return FileItem(name: name, path: join(path, name), isDirectory: false, size: object.size,
                            modified: object.modified)
        }
        return folders + files
    }

    // MARK: Folders and files

    func createFolder(at path: String) async throws {
        let (bucket, key) = Self.split(path)
        if key.isEmpty {
            try await client.createBucket(bucket)
        } else {
            try await client.putEmpty(bucket: bucket, key: key + "/")
        }
    }

    func makeDirectory(_ path: String) async throws {
        let (bucket, key) = Self.split(path)
        if key.isEmpty { return } // uploading into a bucket that's already open
        try await client.putEmpty(bucket: bucket, key: key + "/")
    }

    /// No rename in S3: copy every object to the new name, then delete the old ones.
    func move(_ path: String, to newPath: String) async throws {
        let from = Self.split(path), to = Self.split(newPath)
        guard !from.key.isEmpty, !to.key.isEmpty else { throw S3Error(status: 0, code: "BucketRename", message: "") }
        for (source, target) in try await pairs(from: from, to: to) {
            try await client.copy(from: (from.bucket, source), to: (to.bucket, target))
        }
        try await remove(path, isDirectory: !(await client.exists(bucket: from.bucket, key: from.key)))
    }

    func copy(_ item: FileItem, to newPath: String) async throws {
        let from = Self.split(item.path), to = Self.split(newPath)
        for (source, target) in try await pairs(from: from, to: to) {
            try await client.copy(from: (from.bucket, source), to: (to.bucket, target))
        }
    }

    /// Source and target keys for a file, or for every object under a folder.
    private func pairs(from: (bucket: String, key: String), to: (bucket: String, key: String)) async throws
        -> [(String, String)] {
        if await client.exists(bucket: from.bucket, key: from.key) {
            return [(from.key, to.key)]
        }
        let prefix = from.key + "/"
        let objects = try await client.list(bucket: from.bucket, prefix: prefix, recursive: true).objects
        return objects.map { ($0.key, to.key + "/" + $0.key.dropFirst(prefix.count)) }
    }

    func delete(_ item: FileItem) async throws {
        try await remove(item.path, isDirectory: item.isDirectory)
    }

    func remove(_ path: String, isDirectory: Bool) async throws {
        let (bucket, key) = Self.split(path)
        guard isDirectory else { return try await client.delete(bucket: bucket, key: key) }
        let prefix = key.isEmpty ? "" : key + "/"
        for object in try await client.list(bucket: bucket, prefix: prefix, recursive: true).objects {
            try await client.delete(bucket: bucket, key: object.key)
        }
        if key.isEmpty { try await client.deleteBucket(bucket) }
    }

    // MARK: Transfers

    func upload(from local: URL, to remotePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let (bucket, key) = Self.split(remotePath)
        try await client.upload(from: local, bucket: bucket, key: key, progress: progress)
    }

    func download(from remotePath: String, size: Int64, to local: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        let (bucket, key) = Self.split(remotePath)
        try await client.download(bucket: bucket, key: key, to: local, progress: progress)
    }

    func disconnect() async {}

    /// Buckets can't be renamed, so the pane asks for the name before creating one.
    func namesFolderFirst(in folder: String) -> Bool { folder == "/" }
}
