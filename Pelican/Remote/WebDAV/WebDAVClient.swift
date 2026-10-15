import Foundation

/// A failed WebDAV request: the HTTP status, and whether the address answered like a plain
/// website rather than a WebDAV server.
struct WebDAVError: Error, LocalizedError, Sendable {
    let status: Int
    var notWebDAV = false
    var errorDescription: String? { "\(status) \(HTTPURLResponse.localizedString(forStatusCode: status))" }
}

/// Talks WebDAV (RFC 4918) over HTTPS, or HTTP on the local network. Pane paths like "/a/b"
/// are relative to the address's own path, so "https://cloud.example.com/remote.php/dav/files/me"
/// shows that folder as "/".
final class WebDAVClient: Sendable {
    struct Entry: Sendable { let name: String; let isDirectory: Bool; let size: Int64?; let modified: Date? }

    let base: URL
    private let session: URLSession

    init(base: URL, user: String, password: String) {
        self.base = base
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: configuration,
                                  delegate: Authenticator(user: user, password: password), delegateQueue: nil)
    }

    /// "cloud.example.com/dav" or "http://127.0.0.1" plus the form's port. A port written in the
    /// address wins; HTTP with the untouched HTTPS port means port 80.
    static func baseURL(for server: Server) throws -> URL {
        var address = server.host.trimmingCharacters(in: .whitespaces)
        if !address.contains("://") { address = "https://" + address }
        guard var components = URLComponents(string: address), components.host?.isEmpty == false,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            throw URLError(.badURL)
        }
        if components.port == nil {
            let standard = components.scheme?.lowercased() == "http" ? 80 : 443
            let port = components.scheme?.lowercased() == "http" && server.port == 443 ? 80 : server.port
            components.port = port == standard || port == 0 ? nil : port
        }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    // MARK: Requests

    /// The folder itself (Depth 0), or its contents (Depth 1).
    func list(_ path: String) async throws -> [Entry] {
        let url = url(for: path, directory: true)
        let entries = try await propfind(url, depth: "1")
        let own = Self.trimmed(url.path(percentEncoded: false))
        return entries.filter { Self.trimmed($0.path) != own && !$0.entry.name.isEmpty }.map(\.entry)
    }

    /// Throws unless `path` is a folder this account can read; used when connecting.
    func checkFolder(_ path: String) async throws {
        let entries = try await propfind(url(for: path, directory: true), depth: "0")
        guard entries.first?.entry.isDirectory != false else { throw WebDAVError(status: 409) }
    }

    func makeCollection(_ path: String) async throws {
        try await send("MKCOL", url(for: path, directory: true))
    }

    func delete(_ path: String, isDirectory: Bool) async throws {
        try await send("DELETE", url(for: path, directory: isDirectory))
    }

    func move(_ path: String, to newPath: String) async throws {
        try await send("MOVE", url(for: path, directory: false),
                       headers: ["Destination": url(for: newPath, directory: false).absoluteString, "Overwrite": "F"])
    }

    func copy(_ path: String, to newPath: String, isDirectory: Bool) async throws {
        try await send("COPY", url(for: path, directory: isDirectory),
                       headers: ["Destination": url(for: newPath, directory: isDirectory).absoluteString,
                                 "Overwrite": "F", "Depth": "infinity"])
    }

    func upload(from local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url(for: path, directory: false))
        request.httpMethod = "PUT"
        let size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let tracker = ProgressTracker(report: progress)
        let (_, response) = try await session.upload(for: request, fromFile: local, delegate: tracker)
        try check(response)
        tracker.finish(total: size)
    }

    func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let tracker = ProgressTracker(report: progress)
        let (file, response) = try await session.download(for: URLRequest(url: url(for: path, directory: false)),
                                                          delegate: tracker)
        defer { try? FileManager.default.removeItem(at: file) }
        try check(response)
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: file, to: local)
        tracker.finish(total: Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }

    // MARK: Plumbing

    private static let propfindBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/><D:getcontentlength/><D:getlastmodified/></D:prop></D:propfind>
        """.utf8)

    private func propfind(_ url: URL, depth: String) async throws -> [(path: String, entry: Entry)] {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A plain website either refuses PROPFIND or answers it like a GET.
        if status == 405 || status == 501 || (200..<300).contains(status) && status != 207 {
            throw WebDAVError(status: status, notWebDAV: true)
        }
        try check(response)
        guard let xml = S3XML.parse(data, localNames: true), xml.name == "multistatus" else {
            throw WebDAVError(status: status, notWebDAV: true)
        }
        return xml.all("response").compactMap(Self.entry)
    }

    /// One `<response>`: its decoded path plus the properties the server could give (status 200).
    private static func entry(_ response: S3XML) -> (path: String, entry: Entry)? {
        guard let href = response.value("href")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var path = href
        if let scheme = path.range(of: "://") {
            path = path[scheme.upperBound...].firstIndex(of: "/").map { String(path[$0...]) } ?? "/"
        }
        path = path.removingPercentEncoding ?? path
        var isDirectory = false, size: Int64?, modified: Date?
        for propstat in response.all("propstat") where propstat.value("status").map({ $0.contains(" 2") }) ?? true {
            guard let prop = propstat["prop"] else { continue }
            if prop["resourcetype"]?["collection"] != nil { isDirectory = true }
            if let length = prop.value("getcontentlength").flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }) {
                size = length
            }
            if let date = prop.value("getlastmodified").flatMap(parseDate) { modified = date }
        }
        let name = (trimmed(path) as NSString).lastPathComponent
        return (path, Entry(name: name == "/" ? "" : name, isDirectory: isDirectory,
                            size: isDirectory ? nil : size, modified: modified))
    }

    @discardableResult
    private func send(_ method: String, _ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        try check(response)
        return data
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        throw WebDAVError(status: http.statusCode)
    }

    /// The pane path under the base address, each part percent-encoded; folders end in "/",
    /// since many servers redirect "/folder" to "/folder/" and a redirect can drop the method.
    /// Names go out precomposed (NFC): macOS file names are often decomposed, and servers
    /// like Nextcloud would otherwise show "ü" as "u" plus a separate dot pair.
    func url(for path: String, directory: Bool) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let parts = path.precomposedStringWithCanonicalMapping.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? String($0)
        }
        var encoded = components.percentEncodedPath + "/" + parts.joined(separator: "/")
        if directory, !encoded.hasSuffix("/") { encoded += "/" }
        components.percentEncodedPath = encoded
        return components.url!
    }

    private static let segmentAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~!$&'()*+,;=:@"))
        .subtracting(CharacterSet(charactersIn: "&+;="))

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }
}

/// Answers the server's Basic, Digest or NTLM challenge with the saved user name and password.
/// After a refusal it stops answering, so the request ends with a 401 instead of looping.
private final class Authenticator: NSObject, URLSessionTaskDelegate, Sendable {
    let user: String
    let password: String

    init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
             NSURLAuthenticationMethodDefault:
            guard challenge.previousFailureCount == 0 else { return (.rejectProtectionSpace, nil) }
            return (.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
        default:
            return (.performDefaultHandling, nil)
        }
    }

    /// Keeps the method and headers when the server moves a request to another path on the same host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let original = task.originalRequest, let target = request.url,
              target.host() == original.url?.host() else { return request }
        var kept = original
        kept.url = target
        return kept
    }
}
