import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3 and S3-compatible services (R2, MinIO, Wasabi…).
struct S3Signer: Sendable {
    let accessKey: String
    let secretKey: String

    static let emptyPayloadHash = SHA256.hash(data: Data()).hex
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// Signs `request` in place. Its URL must already carry the percent-encoded path and query
    /// built by `S3Signer.encode`, so what's signed is exactly what's sent.
    func sign(_ request: inout URLRequest, region: String, payloadHash: String, date: Date = .now) {
        guard let url = request.url, let host = url.host() else { return }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let stamp = Self.formatter("yyyyMMdd'T'HHmmss'Z'").string(from: date)
        let day = String(stamp.prefix(8))

        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(stamp, forHTTPHeaderField: "x-amz-date")

        var headers: [String: String] = ["host": hostHeader]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if lower.hasPrefix("x-amz-") || lower == "content-type" || lower == "content-md5" {
                headers[lower] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let canonicalHeaders = headers.keys.sorted().map { "\($0):\(headers[$0]!)\n" }.joined()

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
        let query = Self.canonicalQuery(components?.percentEncodedQuery ?? "")

        let canonicalRequest = [request.httpMethod ?? "GET", path, query, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", stamp, scope, SHA256.hash(data: Data(canonicalRequest.utf8)).hex]
            .joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, "s3", "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)).hex
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// Query pairs sorted by name, then value, as SigV4 requires.
    private static func canonicalQuery(_ query: String) -> String {
        var pairs: [(name: String, value: String)] = []
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            pairs.append((String(parts[0]), parts.count > 1 ? String(parts[1]) : ""))
        }
        pairs.sort { lhs, rhs in lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name }
        return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// S3's URI encoding: everything except unreserved characters, optionally keeping "/".
    static func encode(_ value: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
