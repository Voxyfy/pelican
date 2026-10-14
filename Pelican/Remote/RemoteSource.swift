import Foundation

/// A server pane's source, whatever the protocol. The transfer queue and the window only
/// talk to this, so SFTP and FTP share every transfer and file operation.
protocol RemoteSource: FileSource, AnyObject {
    var server: Server { get }
    func makeDirectory(_ path: String) async throws
    func upload(from local: URL, to remotePath: String,
                progress: @escaping @Sendable (Int64) -> Void) async throws
    func download(from remotePath: String, size: Int64, to local: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
    func remove(_ path: String, isDirectory: Bool) async throws
    func disconnect() async
}

extension RemoteSource {
    /// Everything under `path` (files and folders), depth first, for folder downloads.
    func walk(_ path: String) async throws -> [FileItem] {
        var result: [FileItem] = []
        for item in try await list(path) {
            result.append(item)
            if item.isDirectory { result += try await walk(item.path) }
        }
        return result
    }
}

/// Opens the right kind of connection for a server.
enum Remote {
    static func connect(to server: Server, credential: Credential) async throws -> any RemoteSource {
        switch server.kind {
        case .sftp:
            return try await SFTPFileSource.connect(to: server, credential: credential)
        case .ftp, .ftps:
            guard case .password(let password) = credential else { throw SSHKey.Problem.keyNeedsSFTP }
            return try await FTPFileSource.connect(to: server, password: password)
        default:
            throw CocoaError(.featureUnsupported)
        }
    }
}
