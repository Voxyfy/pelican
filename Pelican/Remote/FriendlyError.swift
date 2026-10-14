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
        case let s3 as S3Error where ["InvalidAccessKeyId", "SignatureDoesNotMatch"].contains(s3.code):
            return String(localized: "The access key ID or secret access key is incorrect.")
        case let s3 as S3Error where s3.code == "AccessDenied" && server.remotePath?.isEmpty != false:
            return String(localized: "This key can't list buckets. Enter a bucket name, for example /my-bucket.")
        case let s3 as S3Error:
            return transferMessage(for: s3)
        case let url as URLError where url.code == .cannotFindHost:
            return String(localized: "Can't find a server called \(server.host).")
        case let url as URLError where url.code == .cannotConnectToHost:
            return String(localized: "\(server.host) refused the connection on port \(String(server.port)).")
        case let url as URLError where url.code == .badURL:
            return String(localized: "Check the endpoint address.")
        case let ftp as FTPError where ftp.reply.code == 530:
            return String(localized: "The user name or password is incorrect.")
        case let ftp as FTPError where ftp.reply.code == 534 || (ftp.reply.code >= 500 && ftp.reply.text.uppercased().contains("TLS")):
            return String(localized: "\(server.host) doesn't offer FTP with TLS/SSL. Try plain FTP, or ask your host.")
        case is FTPConnectionClosed:
            return String(localized: "The connection was lost.")
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
        if let ftp = error as? FTPError {
            if ftp.reply.code == 425, ftp.reply.text.lowercased().contains("resum") {
                return String(localized: "This server requires TLS session reuse on file transfers, which Pelican doesn't support yet. Use SFTP or plain FTP for now.")
            }
            switch ftp.reply.code {
            case 421, 425, 426: return String(localized: "The connection was lost.")
            case 550, 553: return String(localized: "The server refused: \(ftp.reply.text)")
            case 552: return String(localized: "The server is out of space for this file.")
            default: return "\(ftp.reply.code) \(ftp.reply.text)"
            }
        }
        if error is FTPConnectionClosed { return String(localized: "The connection was lost.") }
        if let s3 = error as? S3Error {
            switch s3.code {
            case "AccessDenied": return String(localized: "This key isn't allowed to do that.")
            case "NoSuchBucket": return String(localized: "That bucket doesn't exist.")
            case "BucketAlreadyExists": return String(localized: "That bucket name is taken. Bucket names are shared by everyone.")
            case "BucketNotEmpty": return String(localized: "The bucket isn't empty.")
            case "BucketRename": return String(localized: "Buckets can't be renamed.")
            default: return s3.localizedDescription
            }
        }
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
