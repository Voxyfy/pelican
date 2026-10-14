import CryptoKit
import XCTest
@testable import Pelican

/// S3 against Versity Gateway in Docker (see README). Skipped when it isn't running.
@MainActor
final class S3Tests: XCTestCase {
    private var server: Server {
        var server = Server(name: "S3", host: "http://127.0.0.1", port: 9000, username: "pelican")
        server.kind = .s3
        return server
    }
    private let secret = "pelican-test-secret"
    private var source: (any RemoteSource)!
    private var base = ""
    private var work: URL!

    override func setUp() async throws {
        do {
            source = try await Remote.connect(to: server, credential: .password(secret))
        } catch let error as URLError {
            throw XCTSkip("S3 test server not reachable: \(error)")
        }
        try? await source.createFolder(at: "/pelican-test")
        base = "/pelican-test/run-\(UUID().uuidString.prefix(6).lowercased())"
        work = FileManager.default.temporaryDirectory.appending(path: "s3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work.appending(path: "site/css"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? await source?.remove(base, isDirectory: true)
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    func testRootListsBuckets() async throws {
        XCTAssertEqual(source.startPath, "/")
        let buckets = try await source.list("/")
        XCTAssertTrue(buckets.contains { $0.name == "pelican-test" && $0.isDirectory })
    }

    func testWrongSecretIsExplained() async {
        let connection = Connection()
        await connection.test(server, password: "wrong")
        XCTAssertEqual(connection.testState, .failed(String(
            localized: "The access key ID or secret access key is incorrect.", bundle: .main)))
    }

    func testRoundTripMultipartCopyRenameDelete() async throws {
        let big = work.appending(path: "big.bin")
        try Data((0..<40_000_123).map { _ in UInt8.random(in: 0...255) }).write(to: big) // over the multipart threshold
        try Data("<h1>Pelican</h1>".utf8).write(to: work.appending(path: "site/index.html"))
        try Data("body{}".utf8).write(to: work.appending(path: "site/css/app.css"))

        let queue = TransferQueue()
        let local = try await LocalFileSource(root: work).list(work.path(percentEncoded: false))
        try await source.makeDirectory(base)
        queue.upload(local, to: base, via: source) {}
        try await waitUntilFinished(queue)
        XCTAssertEqual(queue.transfers.map(\.state), [.done, .done], "\(queue.transfers.map(\.state))")
        XCTAssertEqual(queue.transfers.first { $0.name == "big.bin" }?.doneBytes, 40_000_123)

        let listing = try await source.list(base)
        XCTAssertEqual(Set(listing.map(\.name)), ["big.bin", "site"])
        XCTAssertEqual(listing.first { $0.name == "big.bin" }?.size, 40_000_123)

        let back = work.appending(path: "back")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        queue.clearFinished()
        queue.download(listing, to: back.path(percentEncoded: false), via: source) {}
        try await waitUntilFinished(queue)
        XCTAssertEqual(queue.transfers.map(\.state), [.done, .done], "\(queue.transfers.map(\.state))")
        XCTAssertEqual(try digest(back.appending(path: "big.bin")), try digest(big))
        XCTAssertEqual(try digest(back.appending(path: "site/css/app.css")),
                       try digest(work.appending(path: "site/css/app.css")))

        // Server-side copy, rename of a folder (copy + delete), then recursive delete.
        let pane = PaneModel(source: source)
        await pane.navigate(to: base)
        let site = try XCTUnwrap(pane.rows.first { $0.item.name == "site" }?.item)
        await pane.copyInPlace([site], to: base)
        XCTAssertNil(pane.operationError)
        let stem = "site"
        let copyName = String(localized: "\(stem) copy", bundle: .main)
        XCTAssertTrue(pane.rows.contains { $0.item.name == copyName }, "\(pane.rows.map(\.item.name))")

        await pane.rename(site, to: "www")
        XCTAssertNil(pane.operationError)
        let www = try await source.list(base + "/www/css")
        XCTAssertEqual(www.map(\.name), ["app.css"])
        let names = Set(try await source.list(base).map(\.name))
        XCTAssertFalse(names.contains("site"), "Rename should remove the old prefix: \(names)")

        await pane.delete(pane.rows.map(\.item))
        XCTAssertNil(pane.operationError)
        let left = try await source.list(base)
        XCTAssertTrue(left.isEmpty, "\(left.map(\.name))")
    }

    // MARK: Helpers

    private func waitUntilFinished(_ queue: TransferQueue) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while queue.activeCount > 0 {
            guard ContinuousClock.now < deadline else { return XCTFail("Transfers didn't finish in time") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
