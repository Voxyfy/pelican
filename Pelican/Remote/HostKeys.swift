import Crypto
import Foundation
import NIOCore
import NIOSSH

/// Trust on first use, like OpenSSH's known_hosts: the first key a server
/// presents is shown to the user, and once accepted it must never change.
struct HostKeys: Sendable {
    private static let key = "knownHosts"

    static func trusted(for host: String, port: Int) -> String? {
        let known = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        return known?["\(host):\(port)"]
    }

    static func trust(_ openSSHKey: String, host: String, port: Int) {
        var known = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        known["\(host):\(port)"] = openSSHKey
        UserDefaults.standard.set(known, forKey: key)
    }

    static func forget(host: String, port: Int) {
        var known = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        known["\(host):\(port)"] = nil
        UserDefaults.standard.set(known, forKey: key)
    }

    /// "SHA256:…" as printed by `ssh-keygen -lf`, or the certificate's SHA-256 for FTPS.
    static func fingerprint(_ openSSHKey: String) -> String {
        if openSSHKey.hasPrefix("cert ") {
            return "SHA256:" + openSSHKey.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return openSSHKey }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// Raised when the server's key isn't trusted yet, or has changed.
struct HostKeyError: LocalizedError, Sendable {
    let host: String
    let port: Int
    let presentedKey: String
    let changed: Bool
    /// An FTPS certificate macOS couldn't verify, rather than an SSH host key.
    var isCertificate = false

    var errorDescription: String? {
        if changed {
            return String(localized: "The identity of \(host) has changed. Someone may be intercepting the connection.")
        }
        if isCertificate {
            return String(localized: "The certificate of \(host) couldn't be verified. Shared hosting often uses its own certificate; trust it only if you expect that.")
        }
        return String(localized: "Pelican hasn't connected to \(host) before.")
    }
}

final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    private(set) var rejection: HostKeyError?

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        let known = HostKeys.trusted(for: host, port: port)
        if known == presented {
            validationCompletePromise.succeed(())
        } else {
            let error = HostKeyError(host: host, port: port, presentedKey: presented, changed: known != nil)
            rejection = error
            validationCompletePromise.fail(error)
        }
    }
}
