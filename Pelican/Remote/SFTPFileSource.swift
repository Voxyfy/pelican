import Citadel
import Foundation
import NIOSSH

/// Browses a server over SFTP. One SSH connection per open pane.
final class SFTPFileSource: FileSource, @unchecked Sendable {
    let server: Server
    let startPath: String
    let rootPath = "/"
    var displayName: String { server.title }

    private let ssh: SSHClient
    let sftp: SFTPClient

    private init(server: Server, ssh: SSHClient, sftp: SFTPClient, startPath: String) {
        self.server = server
        self.ssh = ssh
        self.sftp = sftp
        self.startPath = startPath
    }

    static func connect(to server: Server, password: String) async throws -> SFTPFileSource {
        try await connect(to: server, credential: .password(password))
    }

    static func connect(to server: Server, credential: Credential) async throws -> SFTPFileSource {
        let validator = HostKeyValidator(host: server.host, port: server.port)
        // Parse the key before dialing, so a bad key or passphrase fails with a clear message.
        let method: SSHAuthenticationMethod
        switch credential {
        case .password(let password):
            method = .passwordBased(username: server.username, password: password)
        case .key(let key, let passphrase):
            method = try SSHKey.authentication(username: server.username, key: key, passphrase: passphrase)
        }
        let auth = Unchecked(method)
        var settings = SSHClientSettings(
            host: server.host,
            port: server.port,
            authenticationMethod: { auth.value },
            hostKeyValidator: .custom(validator)
        )
        settings.connectTimeout = .seconds(15)
        let ssh: SSHClient
        do {
            ssh = try await SSHClient.connect(to: settings)
        } catch {
            // NIO wraps the validator's error; surface ours so the UI can ask to trust the key.
            if let rejection = validator.rejection { throw rejection }
            if case SSHClientError.allAuthenticationOptionsFailed = error,
               case .key(let key, _) = credential, SSHKey.isRSA(key) {
                throw SSHKey.Problem.rsaRefused
            }
            throw error
        }
        let sftp = try await ssh.openSFTP()
        let requested = server.remotePath?.trimmingCharacters(in: .whitespaces) ?? ""
        let start = (try? await sftp.getRealPath(atPath: requested.isEmpty ? "." : requested)) ?? "/"
        return SFTPFileSource(server: server, ssh: ssh, sftp: sftp, startPath: start)
    }

    func list(_ path: String) async throws -> [FileItem] {
        let names = try await sftp.listDirectory(atPath: path)
        return names.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { entry in
                let mode = entry.attributes.permissions ?? 0
                let isDirectory = mode & 0o170000 == 0o040000
                return FileItem(
                    name: entry.filename,
                    path: (path as NSString).appendingPathComponent(entry.filename),
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : entry.attributes.size.map(Int64.init),
                    modified: entry.attributes.accessModificationTime?.modificationTime
                )
            }
    }

    func disconnect() async {
        try? await sftp.close()
        try? await ssh.close()
    }
}
