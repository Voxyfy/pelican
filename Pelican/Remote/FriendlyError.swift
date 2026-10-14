import Citadel
import Foundation
import NIOCore
import NIOPosix

/// Turns SSH and network errors into sentences a user can act on.
enum FriendlyError {
    static func message(for error: Error, server: Server) -> String {
        switch error {
        case let problem as SSHKey.Problem:
            return problem.localizedDescription
        case SSHClientError.allAuthenticationOptionsFailed where server.usesKey == true:
            return String(localized: "The server didn't accept this key. Check that its public key is in authorized_keys.")
        case SSHClientError.allAuthenticationOptionsFailed,
             SSHClientError.unsupportedPasswordAuthentication:
            return String(localized: "The user name or password is incorrect.")
        case ChannelError.connectTimeout:
            return String(localized: "\(server.host) didn't answer. Check the address and port.")
        case let error as NIOConnectionError:
            if error.dnsAError != nil || error.dnsAAAAError != nil {
                return String(localized: "Can't find a server called \(server.host).")
            }
            if let refused = error.connectionErrors.first?.error as? IOError,
               refused.errnoCode == ECONNREFUSED {
                return String(localized: "\(server.host) refused the connection on port \(String(server.port)).")
            }
            return String(localized: "Can't reach \(server.host) on port \(String(server.port)).")
        case let error as IOError where error.errnoCode == ECONNREFUSED:
            return String(localized: "\(server.host) refused the connection on port \(String(server.port)).")
        case SFTPError.missingResponse, SSHClientError.channelCreationFailed:
            return String(localized: "Signed in, but the server doesn't offer SFTP.")
        default:
            return transferMessage(for: error)
        }
    }

    /// Errors while reading or writing files, where there's no server address to mention.
    static func transferMessage(for error: Error) -> String {
        // Citadel throws a server status either bare or wrapped, depending on the call.
        let status: SFTPMessage.Status
        if let bare = error as? SFTPMessage.Status {
            status = bare
        } else if case SFTPError.errorStatus(let wrapped) = error {
            status = wrapped
        } else {
            return error.localizedDescription
        }
        switch status.errorCode {
        case .permissionDenied: return String(localized: "The server doesn't allow this here.")
        case .noSuchFile: return String(localized: "The file or folder no longer exists.")
        case .connectionLost, .noConnection: return String(localized: "The connection was lost.")
        default: return status.message.isEmpty ? error.localizedDescription : status.message
        }
    }
}
