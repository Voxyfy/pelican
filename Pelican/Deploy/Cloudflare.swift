import Foundation

/// Clears Cloudflare's cache after a deploy, so visitors see the new files right away.
enum Cloudflare {
    nonisolated(unsafe) static var apiBase = URL(string: "https://api.cloudflare.com/client/v4")!
    nonisolated(unsafe) static var session = URLSession(configuration: .ephemeral)

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Purges `urls` (30 per request, Cloudflare's limit), or everything when `urls` is nil.
    static func purge(zone: String, token: String, urls: [String]?) async throws {
        let endpoint = apiBase.appending(path: "zones/\(zone)/purge_cache")
        let bodies: [[String: Any]] = urls.map { list in
            stride(from: 0, to: list.count, by: 30).map { ["files": Array(list[$0..<min($0 + 30, list.count)])] }
        } ?? [["purge_everything": true]]
        for body in bodies {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard json?["success"] as? Bool == true else {
                let errors = (json?["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String } ?? []
                throw Failure(message: errors.first ?? String(localized: "Cloudflare didn't accept the request."))
            }
        }
    }

    /// Public URLs for the uploaded files; index.html also purges its folder's URL.
    static func urls(for relativePaths: [String], site: String) -> [String] {
        let base = site.hasSuffix("/") ? String(site.dropLast()) : site
        var result: [String] = []
        for path in relativePaths {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            result.append("\(base)/\(encoded)")
            if (path as NSString).lastPathComponent == "index.html" {
                let folder = (encoded as NSString).deletingLastPathComponent
                result.append(folder.isEmpty ? "\(base)/" : "\(base)/\(folder)/")
            }
        }
        return result
    }
}
