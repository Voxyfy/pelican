import Foundation
import Observation

/// A local folder published to a folder on a saved server, e.g. ~/code/site → /public_html.
struct DeployTarget: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var serverID: UUID
    var localPath: String
    /// Security-scoped bookmark, so the sandboxed app can read the folder on later launches.
    var localBookmark: Data?
    var remotePath: String
    var excludes: [String] = DeployTarget.defaultExcludes
    /// Delete server files that no longer exist locally. Off by default: it can lose data.
    var deleteRemoved = false
    var cloudflareZone: String?
    /// e.g. https://example.com; when set, only changed URLs are purged instead of everything.
    var siteURL: String?
    var lastDeploy: Date?

    static let defaultExcludes = [".git", ".DS_Store", "node_modules", ".env", ".env.*", ".idea", ".vscode", "*.log"]

    var cloudflareTokenAccount: String { "cloudflare:\(id.uuidString)" }
    var usesCloudflare: Bool { !(cloudflareZone ?? "").isEmpty }

    /// Opens the local folder for reading; balance with `stopAccessingSecurityScopedResource`.
    func openLocalFolder() -> URL? {
        if let localBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: localBookmark, options: .withSecurityScope,
                                  bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                return url
            }
        }
        let url = URL(filePath: localPath, directoryHint: .isDirectory)
        return FileManager.default.isReadableFile(atPath: localPath) ? url : nil
    }
}

/// Saved deploy targets, kept like Favorites.
@MainActor @Observable
final class DeployTargets {
    private static let key = "deployTargets"
    private(set) var all: [DeployTarget] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([DeployTarget].self, from: data) {
            all = saved
        }
    }

    func targets(for server: Server) -> [DeployTarget] { all.filter { $0.serverID == server.id } }

    func save(_ target: DeployTarget) {
        if let index = all.firstIndex(where: { $0.id == target.id }) { all[index] = target } else { all.append(target) }
        persist()
    }

    func remove(_ target: DeployTarget) {
        all.removeAll { $0.id == target.id }
        Keychain.deletePassword(account: target.cloudflareTokenAccount)
        DeployManifest.delete(for: target)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.key)
    }
}

/// What the last successful deploy sent: relative path → size and modification time.
/// Comparing against this, not the server's clock, decides what changed.
struct DeployManifest: Codable, Sendable {
    struct Entry: Codable, Hashable, Sendable { let size: Int64; let modified: TimeInterval }
    var files: [String: Entry] = [:]

    private static func url(for target: DeployTarget) -> URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Pelican/Deploys", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "\(target.id.uuidString).json")
    }

    static func load(for target: DeployTarget) -> DeployManifest {
        (try? JSONDecoder().decode(DeployManifest.self, from: Data(contentsOf: url(for: target)))) ?? DeployManifest()
    }

    func save(for target: DeployTarget) {
        try? JSONEncoder().encode(self).write(to: Self.url(for: target))
    }

    static func delete(for target: DeployTarget) {
        try? FileManager.default.removeItem(at: url(for: target))
    }
}
