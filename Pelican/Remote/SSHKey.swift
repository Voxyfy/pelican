import Citadel
import Crypto
import Foundation
import _CryptoExtras

/// How the user proves who they are: a password, or a private key with an optional passphrase.
enum Credential: Sendable {
    case password(String)
    case key(String, passphrase: String)
}

/// Reading OpenSSH private keys (ed25519 and RSA) and turning them into an SSH sign-in.
enum SSHKey {
    enum Problem: LocalizedError, Equatable {
        case notOpenSSH, unsupportedType(String), passphraseNeeded, wrongPassphrase
        /// An RSA key the server turned down. Usually the server is OpenSSH 8.8 or newer, which no
        /// longer accepts the SHA-1 RSA signatures Citadel makes.
        case rsaRefused
        /// FTP has no key sign-in.
        case keyNeedsSFTP

        var errorDescription: String? {
            switch self {
            case .notOpenSSH:
                String(localized: "This isn't an OpenSSH private key. Convert it with: ssh-keygen -p -f <key>")
            case .unsupportedType(let type):
                String(localized: "\(type) keys aren't supported yet. Use an ed25519 or RSA key.")
            case .passphraseNeeded:
                String(localized: "This key is protected. Enter its passphrase.")
            case .wrongPassphrase:
                String(localized: "The key's passphrase is incorrect.")
            case .keyNeedsSFTP:
                String(localized: "SSH keys only work with SFTP. Use a password for FTP.")
            case .rsaRefused:
                String(localized: "The server didn't accept this RSA key. Newer servers refuse the RSA signature Pelican uses for now. Try an ed25519 key (ssh-keygen -t ed25519), and check that the public key is in authorized_keys.")
            }
        }
    }

    /// Checks a key right after it's chosen. Returns whether it needs a passphrase.
    static func inspect(_ text: String) throws -> Bool {
        do {
            _ = try authentication(username: "", key: text, passphrase: "")
            return false
        } catch Problem.passphraseNeeded {
            return true
        }
    }

    static func isRSA(_ text: String) -> Bool {
        (try? SSHKeyDetection.detectPrivateKeyType(from: text)) == .rsa
    }

    static func authentication(username: String, key text: String, passphrase: String) throws -> SSHAuthenticationMethod {
        let type: SSHKeyType
        do {
            type = try SSHKeyDetection.detectPrivateKeyType(from: text)
        } catch SSHKeyDetectionError.unsupportedKeyType(let name) {
            throw Problem.unsupportedType(name ?? "?")
        } catch {
            throw Problem.notOpenSSH
        }
        let decryption = passphrase.isEmpty ? nil : Data(passphrase.utf8)
        do {
            switch type {
            case .ed25519:
                return .ed25519(username: username,
                                privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryption))
            case .rsa:
                return .rsa(username: username,
                            privateKey: try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryption))
            default:
                throw Problem.unsupportedType(type.description)
            }
        } catch let problem as Problem {
            throw problem
        } catch {
            // Citadel's key errors are internal types; tell them apart by whether a passphrase was given.
            if String(describing: error).contains("missingDecryptionKey") { throw Problem.passphraseNeeded }
            throw passphrase.isEmpty ? Problem.notOpenSSH : Problem.wrongPassphrase
        }
    }
}
