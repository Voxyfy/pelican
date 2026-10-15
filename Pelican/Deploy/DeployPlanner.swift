import Darwin
import Foundation

/// What a deploy will do, worked out before anything is sent.
struct DeployPlan: Sendable {
    struct LocalFile: Sendable, Hashable {
        let relative: String
        let url: URL
        let size: Int64
        let modified: TimeInterval
    }

    var uploads: [LocalFile] = []
    /// Relative paths on the server that will be deleted (only with "delete removed" on).
    var deletions: [String] = []
    var unchanged = 0
    /// Server folders that must exist before the uploads, parents first.
    var foldersToCreate: [String] = []
    /// The manifest to save once the deploy succeeds: every local file as it is now.
    var manifest = DeployManifest()

    var uploadBytes: Int64 { uploads.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { uploads.isEmpty && deletions.isEmpty }
}

enum DeployPlanner {
    /// Compares the local folder with the last deploy and the server, without changing anything.
    static func plan(local root: URL, remote: any RemoteSource, remoteRoot: String, excludes: [String],
                     deleteRemoved: Bool, manifest: DeployManifest) async throws -> DeployPlan {
        let localFiles = try scanLocal(root, excludes: excludes)
        let remoteItems = (try? await remote.walk(remoteRoot)) ?? []
        let prefix = remoteRoot.hasSuffix("/") ? remoteRoot : remoteRoot + "/"
        var remoteFiles: [String: FileItem] = [:]
        var remoteFolders: Set<String> = []
        for item in remoteItems {
            let relative = String(item.path.dropFirst(prefix.count))
            if item.isDirectory { remoteFolders.insert(relative) } else { remoteFiles[relative] = item }
        }

        var plan = DeployPlan()
        for file in localFiles {
            plan.manifest.files[file.relative] = .init(size: file.size, modified: file.modified)
            let onServer = remoteFiles[file.relative]
            let changed: Bool
            if let last = manifest.files[file.relative] {
                // Sent before: changed if edited locally since, or if the server copy went missing.
                changed = last.size != file.size || abs(last.modified - file.modified) >= 1 || onServer?.size != file.size
            } else if let onServer, onServer.size == file.size, let date = onServer.modified,
                      date.timeIntervalSince1970 >= file.modified.rounded(.down) {
                // First deploy: same size and not older on the server. Servers report whole
                // seconds while this Mac keeps fractions, so compare at second precision.
                changed = false
            } else {
                changed = true
            }
            if changed { plan.uploads.append(file) } else { plan.unchanged += 1 }
        }

        if deleteRemoved {
            let localSet = Set(localFiles.map(\.relative))
            plan.deletions = remoteFiles.keys
                .filter { !localSet.contains($0) && !isExcluded($0, by: excludes) }
                .sorted()
        }

        var needed: Set<String> = []
        for file in plan.uploads {
            var parent = (file.relative as NSString).deletingLastPathComponent
            while !parent.isEmpty, !remoteFolders.contains(parent), needed.insert(parent).inserted {
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        plan.foldersToCreate = needed.sorted { lhs, rhs in
            let depths = (lhs.split(separator: "/").count, rhs.split(separator: "/").count)
            return depths.0 == depths.1 ? lhs < rhs : depths.0 < depths.1
        }
        return plan
    }

    static func scanLocal(_ root: URL, excludes: [String]) throws -> [DeployPlan.LocalFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        let base = root.standardizedFileURL.path(percentEncoded: false)
        var files: [DeployPlan.LocalFile] = []
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let values = try url.resourceValues(forKeys: Set(keys))
            if isExcluded(relative, by: excludes) {
                if values.isDirectory == true { walker.skipDescendants() }
                continue
            }
            guard values.isDirectory != true else { continue }
            files.append(.init(relative: relative, url: url, size: Int64(values.fileSize ?? 0),
                               modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return files
    }

    /// "node_modules" or "*.log" match any path component; "storage/logs" matches that path and below.
    static func isExcluded(_ relative: String, by patterns: [String]) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { continue }
            if pattern.contains("/") {
                if fnmatch(pattern, relative, 0) == 0 || relative.hasPrefix(pattern + "/") { return true }
            } else if parts.contains(where: { fnmatch(pattern, $0, 0) == 0 }) {
                return true
            }
        }
        return false
    }
}
