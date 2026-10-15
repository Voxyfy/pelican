import CryptoKit
import Foundation
import NIOConcurrencyHelpers

/// An error document from S3: `<Error><Code>AccessDenied</Code><Message>…</Message></Error>`.
struct S3Error: Error, LocalizedError, Sendable {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { message.isEmpty ? "\(status) \(code)" : message }
}

/// Talks to an S3-compatible endpoint over HTTPS (or HTTP on the local network, for testing).
final class S3Client: Sendable {
    struct Object: Sendable { let key: String; let size: Int64; let modified: Date? }
    struct Listing: Sendable { var folders: [String] = []; var objects: [Object] = [] }

    let endpoint: URL
    private let signer: S3Signer
    private let defaultRegion: String
    private let virtualHosted: Bool
    private let session: URLSession
    /// AWS answers with the right region when a bucket lives elsewhere; remember it per bucket.
    private let regions = NIOLockedValueBox<[String: String]>([:])

    init(endpoint: URL, accessKey: String, secretKey: String, region: String) {
        self.endpoint = endpoint
        self.signer = S3Signer(accessKey: accessKey, secretKey: secretKey)
        self.defaultRegion = region
        self.virtualHosted = endpoint.host()?.hasSuffix("amazonaws.com") == true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: configuration)
    }

    // MARK: Buckets

    func listBuckets() async throws -> [String] {
        let xml = try await xmlRequest("GET", bucket: nil)
        return xml["Buckets"]?.all("Bucket").compactMap { $0.value("Name") } ?? []
    }

    func createBucket(_ bucket: String) async throws {
        let region = self.region(for: bucket)
        var body: Data?
        if virtualHosted, region != "us-east-1" {
            body = Data("""
                <CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
                <LocationConstraint>\(region)</LocationConstraint></CreateBucketConfiguration>
                """.utf8)
        }
        _ = try await request("PUT", bucket: bucket, body: body)
    }

    func deleteBucket(_ bucket: String) async throws {
        _ = try await request("DELETE", bucket: bucket)
    }

    // MARK: Objects

    /// One level under `prefix`: sub-"folders" (common prefixes) and objects.
    func list(bucket: String, prefix: String, recursive: Bool = false, limit: Int? = nil) async throws -> Listing {
        var listing = Listing()
        var token: String?
        repeat {
            var query = ["list-type": "2", "prefix": prefix]
            if !recursive { query["delimiter"] = "/" }
            if let token { query["continuation-token"] = token }
            if let limit { query["max-keys"] = String(limit) }
            let xml = try await xmlRequest("GET", bucket: bucket, query: query)
            listing.folders += xml.all("CommonPrefixes").compactMap { $0.value("Prefix") }
            listing.objects += xml.all("Contents").compactMap { item in
                guard let key = item.value("Key") else { return nil }
                return Object(key: key, size: Int64(item.value("Size") ?? "") ?? 0,
                              modified: item.value("LastModified").flatMap(Self.parseDate))
            }
            token = xml.value("IsTruncated") == "true" ? xml.value("NextContinuationToken") : nil
        } while token != nil && limit == nil
        return listing
    }

    func exists(bucket: String, key: String) async -> Bool {
        (try? await request("HEAD", bucket: bucket, key: key)) != nil
    }

    func putEmpty(bucket: String, key: String) async throws {
        _ = try await request("PUT", bucket: bucket, key: key, body: Data())
    }

    func delete(bucket: String, key: String) async throws {
        _ = try await request("DELETE", bucket: bucket, key: key)
    }

    /// Server-side copy; nothing passes through this Mac.
    func copy(from source: (bucket: String, key: String), to target: (bucket: String, key: String)) async throws {
        let header = "/\(source.bucket)/" + S3Signer.encode(source.key, keepSlash: true)
        _ = try await request("PUT", bucket: target.bucket, key: target.key, headers: ["x-amz-copy-source": header])
    }

    // MARK: Transfers

    private static let multipartThreshold: Int64 = 32 * 1024 * 1024
    private static let partSize = 16 * 1024 * 1024

    func upload(from local: URL, bucket: String, key: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > Self.multipartThreshold else {
            var request = try makeRequest("PUT", bucket: bucket, key: key, payloadHash: S3Signer.unsignedPayload)
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
            let tracker = ProgressTracker(report: progress)
            let (data, response) = try await session.upload(for: request, fromFile: local, delegate: tracker)
            try check(data, response)
            tracker.finish(total: size)
            return
        }
        try await multipartUpload(from: local, bucket: bucket, key: key, progress: progress)
    }

    private func multipartUpload(from local: URL, bucket: String, key: String,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws {
        let created = try await xmlRequest("POST", bucket: bucket, key: key, query: ["uploads": ""])
        guard let uploadID = created.value("UploadId") else { throw S3Error(status: 0, code: "NoUploadId", message: "") }
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        do {
            var parts: [(Int, String)] = []
            var number = 1
            while let chunk = try input.read(upToCount: Self.partSize), !chunk.isEmpty {
                try Task.checkCancellation()
                var request = try makeRequest("PUT", bucket: bucket, key: key,
                                              query: ["partNumber": String(number), "uploadId": uploadID],
                                              payloadHash: S3Signer.unsignedPayload)
                request.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
                let tracker = ProgressTracker(report: progress)
                let (data, response) = try await session.upload(for: request, from: chunk, delegate: tracker)
                try check(data, response)
                tracker.finish(total: Int64(chunk.count))
                let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") ?? ""
                parts.append((number, etag))
                number += 1
            }
            let body = "<CompleteMultipartUpload>" + parts.map {
                "<Part><PartNumber>\($0.0)</PartNumber><ETag>\($0.1)</ETag></Part>"
            }.joined() + "</CompleteMultipartUpload>"
            _ = try await xmlRequest("POST", bucket: bucket, key: key, query: ["uploadId": uploadID], body: Data(body.utf8))
        } catch {
            _ = try? await request("DELETE", bucket: bucket, key: key, query: ["uploadId": uploadID])
            throw error
        }
    }

    func download(bucket: String, key: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let request = try makeRequest("GET", bucket: bucket, key: key, payloadHash: S3Signer.emptyPayloadHash)
        let tracker = ProgressTracker(report: progress)
        let (file, response) = try await session.download(for: request, delegate: tracker)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try check((try? Data(contentsOf: file)) ?? Data(), response)
        }
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: file, to: local)
        let size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        tracker.finish(total: size)
    }

    // MARK: Requests

    private func xmlRequest(_ method: String, bucket: String?, key: String = "", query: [String: String] = [:],
                            body: Data? = nil) async throws -> S3XML {
        let data = try await request(method, bucket: bucket, key: key, query: query, body: body)
        return S3XML.parse(data) ?? S3XML(name: "Empty")
    }

    @discardableResult
    private func request(_ method: String, bucket: String?, key: String = "", query: [String: String] = [:],
                         headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
        let hash = body.map { SHA256Hex.of($0) } ?? S3Signer.emptyPayloadHash
        var request = try makeRequest(method, bucket: bucket, key: key, query: query, headers: headers, payloadHash: hash)
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        // A bucket in another region: AWS says which; remember it and try once more.
        if let bucket, let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode),
           let actual = http.value(forHTTPHeaderField: "x-amz-bucket-region"), actual != region(for: bucket) {
            regions.withLockedValue { $0[bucket] = actual }
            return try await self.request(method, bucket: bucket, key: key, query: query, headers: headers, body: body)
        }
        try check(data, response)
        return data
    }

    private func makeRequest(_ method: String, bucket: String?, key: String = "", query: [String: String] = [:],
                             headers: [String: String] = [:], payloadHash: String) throws -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let encodedKey = S3Signer.encode(key, keepSlash: true)
        let useVirtualHost = virtualHosted && bucket.map { !$0.contains(".") } == true
        if let bucket {
            if useVirtualHost {
                components.host = "\(bucket).\(regionalHost(for: bucket))"
                components.percentEncodedPath = "/" + encodedKey
            } else {
                components.percentEncodedPath = "/\(S3Signer.encode(bucket))" + (key.isEmpty ? "" : "/" + encodedKey)
            }
        } else {
            components.percentEncodedPath = "/"
        }
        if !query.isEmpty {
            components.percentEncodedQuery = query.keys.sorted()
                .map { "\(S3Signer.encode($0))=\(S3Signer.encode(query[$0]!))" }
                .joined(separator: "&")
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        signer.sign(&request, region: bucket.map(region(for:)) ?? defaultRegion, payloadHash: payloadHash)
        return request
    }

    private func region(for bucket: String) -> String {
        regions.withLockedValue { $0[bucket] } ?? defaultRegion
    }

    /// s3.amazonaws.com → s3.eu-central-1.amazonaws.com once the bucket's region is known.
    private func regionalHost(for bucket: String) -> String {
        let host = endpoint.host() ?? "s3.amazonaws.com"
        let region = self.region(for: bucket)
        return host == "s3.amazonaws.com" && region != "us-east-1" ? "s3.\(region).amazonaws.com" : host
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let xml = S3XML.parse(data)
        throw S3Error(status: http.statusCode,
                      code: xml?.value("Code") ?? "HTTP\(http.statusCode)",
                      message: xml?.value("Message") ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).hex }
}

/// Turns URLSession's running totals into the transfer queue's byte deltas, and makes sure
/// the full size is counted even if a callback never comes.
final class ProgressTracker: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void
    private let reported = NIOLockedValueBox<Int64>(0)

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    private func advance(to total: Int64) {
        let delta = reported.withLockedValue { done -> Int64 in
            let delta = max(total - done, 0)
            done += delta
            return delta
        }
        if delta > 0 { report(delta) }
    }

    func finish(total: Int64) { advance(to: total) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        advance(to: totalBytesSent)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        advance(to: totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
