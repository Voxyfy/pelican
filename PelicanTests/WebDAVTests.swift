import CryptoKit
import XCTest
@testable import Pelican

/// WebDAV against Apache mod_dav in Docker (see README). Skipped when it isn't running.
@MainActor
final class WebDAVTests: XCTestCase {
    private var server: Server {
        var server = Server(name: "WebDAV", host: "http://127.0.0.1", port: 8088, username: "pelican")
        server.kind = .webdav
        return server
    }
    private let password = "pelican-test"
    private var source: (any RemoteSource)!
    private var base = ""
    private var work: URL!

    override func setUp() async throws {
        do {
            source = try await Remote.connect(to: server, credential: .password(password))
        } catch let error as URLError {
            throw XCTSkip("WebDAV test server not reachable: \(error)")
        }
        base = "/run \(UUID().uuidString.prefix(6).lowercased())"
        work = FileManager.default.temporaryDirectory.appending(path: "dav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work.appending(path: "site/css"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? await source?.remove(base, isDirectory: true)
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    func testAddressKeepsPathAndPicksPort() throws {
        var server = server
        server.host = "cloud.example.com/remote.php/dav/files/me/"
        server.port = 443
        XCTAssertEqual(try WebDAVClient.baseURL(for: server).absoluteString,
                       "https://cloud.example.com/remote.php/dav/files/me")
        server.host = "http://nas.local"
        XCTAssertEqual(try WebDAVClient.baseURL(for: server).absoluteString, "http://nas.local")
        server.host = "https://nas.local:5006/dav"
        XCTAssertEqual(try WebDAVClient.baseURL(for: server).absoluteString, "https://nas.local:5006/dav")
        let client = WebDAVClient(base: try WebDAVClient.baseURL(for: server), user: "", password: "")
        XCTAssertEqual(client.url(for: "/Çay & kahve/a b.txt", directory: false).absoluteString,
                       "https://nas.local:5006/dav/%C3%87ay%20%26%20kahve/a%20b.txt")
        XCTAssertEqual(client.url(for: "/", directory: true).absoluteString, "https://nas.local:5006/dav/")
    }

    func testWrongPasswordIsExplained() async {
        let connection = Connection()
        await connection.test(server, password: "wrong")
        XCTAssertEqual(connection.testState, .failed(String(
            localized: "The user name or password is incorrect.", bundle: .main)))
    }

    func testMissingStartFolderIsExplained() async {
        var server = server
        server.remotePath = "/no-such-folder-\(UUID().uuidString.prefix(4))"
        let connection = Connection()
        await connection.test(server, password: password)
        XCTAssertEqual(connection.testState, .failed(String(
            localized: "That folder doesn't exist on the server.", bundle: .main)))
    }

    /// Second container with Digest sign-in on port 8089 (see README); skipped when it isn't running.
    func testDigestSignIn() async throws {
        var digest = server
        digest.port = 8089
        let connection = Connection()
        await connection.test(digest, password: password)
        if case .failed(let message) = connection.testState, message.contains("refused") {
            throw XCTSkip("Digest test server not running")
        }
        XCTAssertEqual(connection.testState, .succeeded(folder: "/"))
        await connection.test(digest, password: "wrong")
        XCTAssertEqual(connection.testState, .failed(String(
            localized: "The user name or password is incorrect.", bundle: .main)))
    }

    func testWebsiteIsNotMistakenForWebDAV() async throws {
        var site = server
        site.host = "https://example.com"
        site.port = 443
        do {
            _ = try await Remote.connect(to: site, credential: .password("x"))
            XCTFail("example.com isn't a WebDAV server")
        } catch let error as WebDAVError {
            XCTAssertTrue(error.notWebDAV, "\(error)")
        } catch {
            throw XCTSkip("Offline: \(error)")
        }
    }

    func testRoundTripCopyRenameDelete() async throws {
        let big = work.appending(path: "büyük dosya.bin")
        try Data((0..<5_000_123).map { _ in UInt8.random(in: 0...255) }).write(to: big)
        try Data("<h1>Pelican</h1>".utf8).write(to: work.appending(path: "site/index.html"))
        try Data("body{}".utf8).write(to: work.appending(path: "site/css/app & co.css"))

        let queue = TransferQueue()
        let local = try await LocalFileSource(root: work).list(work.path(percentEncoded: false))
        try await source.makeDirectory(base)
        try await source.makeDirectory(base) // already there: no error
        queue.upload(local, to: base, via: source) {}
        try await waitUntilFinished(queue)
        XCTAssertEqual(queue.transfers.map(\.state), [.done, .done], "\(queue.transfers.map(\.state))")

        let listing = try await source.list(base)
        XCTAssertEqual(Set(listing.map(\.name)), ["büyük dosya.bin", "site"])
        XCTAssertEqual(listing.first { $0.name == "büyük dosya.bin" }?.size, 5_000_123)
        XCTAssertEqual(listing.first { $0.name == "site" }?.isDirectory, true)
        XCTAssertNotNil(listing.first { $0.name == "büyük dosya.bin" }?.modified)

        let back = work.appending(path: "back")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        queue.clearFinished()
        queue.download(listing, to: back.path(percentEncoded: false), via: source) {}
        try await waitUntilFinished(queue)
        XCTAssertEqual(queue.transfers.map(\.state), [.done, .done], "\(queue.transfers.map(\.state))")
        XCTAssertEqual(try digest(back.appending(path: "büyük dosya.bin")), try digest(big))
        XCTAssertEqual(try digest(back.appending(path: "site/css/app & co.css")),
                       try digest(work.appending(path: "site/css/app & co.css")))

        // Server-side copy, folder rename, then delete.
        let pane = PaneModel(source: source)
        await pane.navigate(to: base)
        let site = try XCTUnwrap(pane.rows.first { $0.item.name == "site" }?.item)
        await pane.copyInPlace([site], to: base)
        XCTAssertNil(pane.operationError)
        let stem = "site"
        let copyName = String(localized: "\(stem) copy", bundle: .main)
        XCTAssertTrue(pane.rows.contains { $0.item.name == copyName }, "\(pane.rows.map(\.item.name))")
        let copied = try await source.list(base + "/" + copyName + "/css")
        XCTAssertEqual(copied.map(\.name), ["app & co.css"])

        await pane.rename(site, to: "www")
        XCTAssertNil(pane.operationError)
        let www = try await source.list(base + "/www/css")
        XCTAssertEqual(www.map(\.name), ["app & co.css"])
        let names = try await source.list(base).map(\.name)
        XCTAssertFalse(names.contains("site"), "\(names)")

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
