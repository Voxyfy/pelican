import Foundation

/// A saved connection shown under Favorites. The password lives in Keychain, not here.
struct Server: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    /// Folder to open after connecting; the server's home folder when empty.
    var remotePath: String? = nil
    /// Sign in with a private key instead of a password. Optional so older saved servers still decode.
    var usesKey: Bool? = nil
    /// File name of the chosen key, shown in the form; the key itself lives in Keychain.
    var keyName: String? = nil
    /// Stored as optional so servers saved before FTP support still decode (as SFTP).
    var protocolKind: TransferProtocol? = nil

    var kind: TransferProtocol {
        get { protocolKind ?? .sftp }
        set { protocolKind = newValue == .sftp ? nil : newValue }
    }

    var title: String { name.isEmpty ? host : name }
    var keychainAccount: String { "\(username)@\(host):\(port)" }
    var keyAccount: String { keychainAccount + "#key" }
}
