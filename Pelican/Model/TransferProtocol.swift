import Foundation

/// Protocols Pelican speaks or will speak. Raw values are stored with saved servers.
enum TransferProtocol: String, CaseIterable, Identifiable, Codable, Sendable {
    case sftp, ftp, ftps, s3, r2, webdav

    var id: Self { self }
    var defaultPort: Int {
        switch self {
        case .sftp: 22
        case .ftp, .ftps: 21
        case .s3, .r2, .webdav: 443
        }
    }
    /// S3 and R2 sign in with an access key pair rather than a user name and password.
    var usesAccessKeys: Bool { self == .s3 || self == .r2 }

    var title: String {
        switch self {
        case .sftp: "SFTP"
        case .ftp: "FTP"
        case .ftps: String(localized: "FTP with TLS/SSL")
        case .s3: "Amazon S3"
        case .r2: "Cloudflare R2"
        case .webdav: "WebDAV"
        }
    }

    var symbol: String {
        switch self {
        case .sftp, .ftps: "lock.shield.fill"
        case .ftp: "network"
        case .s3, .r2: "cloud.fill"
        case .webdav: "globe"
        }
    }
}
