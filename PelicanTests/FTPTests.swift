import CryptoKit
import XCTest
@testable import Pelican

/// FTP and FTPS against the Pure-FTPd container (see README). Skipped when it isn't running.
@MainActor
final class FTPTests: XCTestCase {
    private func server(_ kind: TransferProtocol) -> Server {
        var server = Server(name: "FTP", host: "127.0.0.1", port: 2121, username: "pelican")
        server.kind = kind
        return server
    }

    private var opened: [any RemoteSource] = []
    private var leftovers: [(any RemoteSource, String)] = []

    override func tearDown() async throws {
        for (source, path) in leftovers { try? await source.remove(path, isDirectory: true) }
        for source in opened { await source.disconnect() }
    }

    private func connect(_ kind: TransferProtocol) async throws -> any RemoteSource {
        do {
            let source = try await Remote.connect(to: server(kind), credential: .password("pelican-test"))
            opened.append(source)
            return source
        } catch let error as HostKeyError {
            throw error
        } catch let error as FTPError {
            throw error
        } catch {
            throw XCTSkip("FTP test server not reachable: \(error)")
        }
    }

    func testPlainFTPListsHome() async throws {
        let source = try await connect(.ftp)
        XCTAssertEqual(source.startPath, "/")
        let names = Set(try await source.list("/").map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["public_html", "logs"]), "\(names)")
        let logs = try await source.list("/logs")
        XCTAssertEqual(logs.first?.size, 1_500_000)
    }

    func testFTPSAsksToTrustSelfSignedCertificateThenWorks() async throws {
        HostKeys.forget(host: "127.0.0.1", port: 2121)
        do {
            _ = try await connect(.ftps)
            XCTFail("A self-signed certificate should need the user's trust")
        } catch let error as HostKeyError {
            XCTAssertTrue(error.isCertificate)
            XCTAssertTrue(HostKeys.fingerprint(error.presentedKey).hasPrefix("SHA256:"))
            HostKeys.trust(error.presentedKey, host: "127.0.0.1", port: 2121)
        }
        let source = try await connect(.ftps)
        let names = Set(try await source.list("/").map(\.name))
        XCTAssertTrue(names.contains("public_html"))
    }

    func testWrongPasswordIsExplained() async throws {
        let connection = Connection()
        await connection.test(server(.ftp), password: "wrong")
        XCTAssertEqual(connection.testState,
                       .failed(String(localized: "The user name or password is incorrect.", bundle: .main)))
    }

    func testRoundTripAndFolderOperationsOverFTPS() async throws {
        try await trustCertificate()
        try await roundTrip(.ftps)
    }

    func testRoundTripAndFolderOperationsOverFTP() async throws {
        try await roundTrip(.ftp)
    }

    // MARK: Helpers

    private func roundTrip(_ kind: TransferProtocol) async throws {
        let source = try await connect(kind)
        let base = "/pelican-\(kind.rawValue)-\(UUID().uuidString.prefix(6))"
        try await source.makeDirectory(base)
        leftovers.append((source, base))

        let work = FileManager.default.temporaryDirectory.appending(path: "ftp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work.appending(path: "site/css"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let big = work.appending(path: "big.bin")
        try Data((0..<2_345_678).map { _ in UInt8.random(in: 0...255) }).write(to: big)
        try Data("<h1>Pelican</h1>".utf8).write(to: work.appending(path: "site/index.html"))
        try Data("body{}".utf8).write(to: work.appending(path: "site/css/app.css"))

        let local = try await LocalFileSource(root: work).list(work.path(percentEncoded: false))
        let queue = TransferQueue()
        queue.upload(local, to: base, via: source) {}
        try await waitUntilFinished(queue)
        XCTAssertEqual(queue.transfers.map(\.state), [.done, .done], "\(queue.transfers.map(\.state))")

        let back = work.appending(path: "back")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        queue.clearFinished()
        queue.download(try await source.list(base), to: back.path(percentEncoded: false), via: source) {}
        try await waitUntilFinished(queue)
        XCTAssertEqual(queue.transfers.map(\.state), [.done, .done], "\(queue.transfers.map(\.state))")
        XCTAssertEqual(try digest(back.appending(path: "big.bin")), try digest(big))
        XCTAssertEqual(try digest(back.appending(path: "site/css/app.css")),
                       try digest(work.appending(path: "site/css/app.css")))

        // Rename, browse while the lane is idle, then delete recursively.
        let pane = PaneModel(source: source)
        await pane.navigate(to: base)
        let site = try XCTUnwrap(pane.rows.first { $0.item.name == "site" }?.item)
        await pane.rename(site, to: "www")
        XCTAssertNil(pane.operationError)
        XCTAssertTrue(pane.rows.contains { $0.item.name == "www" })
        await pane.delete(pane.rows.map(\.item))
        XCTAssertNil(pane.operationError)
        let left = try await source.list(base)
        XCTAssertTrue(left.isEmpty, "\(left.map(\.name))")
    }

    private func trustCertificate() async throws {
        do {
            let source = try await Remote.connect(to: server(.ftps), credential: .password("pelican-test"))
            await source.disconnect()
        } catch let error as HostKeyError {
            HostKeys.trust(error.presentedKey, host: "127.0.0.1", port: 2121)
        } catch {
            throw XCTSkip("FTP test server not reachable: \(error)")
        }
    }

    private func waitUntilFinished(_ queue: TransferQueue) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while queue.activeCount > 0 {
            guard ContinuousClock.now < deadline else { return XCTFail("Transfers didn't finish in time") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
