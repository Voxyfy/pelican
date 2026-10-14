import CryptoKit
import XCTest
@testable import Pelican

/// Round-trips files through the Docker test server (see README). Skipped when it isn't running.
@MainActor
final class TransferTests: XCTestCase {
    private let server = Server(name: "Test", host: "127.0.0.1", port: 2222, username: "pelican")
    private var source: SFTPFileSource!
    private var work: URL!
    private var remoteLeftovers: [(String, Bool)] = []

    override func setUp() async throws {
        do {
            _ = try await SFTPFileSource.connect(to: server, password: "pelican-test")
        } catch let error as HostKeyError {
            HostKeys.trust(error.presentedKey, host: server.host, port: server.port)
        } catch {
            throw XCTSkip("Test SFTP server not reachable: \(error)")
        }
        source = try await SFTPFileSource.connect(to: server, password: "pelican-test")
        work = FileManager.default.temporaryDirectory.appending(path: "pelican-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for (path, isDirectory) in remoteLeftovers {
            try? await source?.remove(path, isDirectory: isDirectory)
        }
        await source?.disconnect()
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    func testFileAndFolderRoundTrip() async throws {
        // A 5 MB file that isn't a multiple of the chunk size, and a nested folder.
        let big = work.appending(path: "big.bin")
        try randomData(5_000_123).write(to: big)
        let site = work.appending(path: "site")
        try FileManager.default.createDirectory(at: site.appending(path: "css"), withIntermediateDirectories: true)
        try Data("<h1>Pelican</h1>".utf8).write(to: site.appending(path: "index.html"))
        try randomData(70_000).write(to: site.appending(path: "css/app.css"))

        let remoteFolder = "/upload/roundtrip-\(UUID().uuidString.prefix(8))"
        try await source.makeDirectory(remoteFolder)
        remoteLeftovers.append((remoteFolder, true))

        let queue = TransferQueue()
        let local = try await localItems([big, site])
        queue.upload(local, to: remoteFolder, via: source) {}
        try await waitUntilFinished(queue)
        XCTAssertEqual(queue.transfers.map(\.state), [.done, .done])
        XCTAssertEqual(queue.transfers.first?.doneBytes, 5_000_123)
        let last = ActivityLog.shared.entries.suffix(2)
        XCTAssertTrue(last.allSatisfy { $0.level == .success }, "Each finished upload should be logged")
        XCTAssertTrue(last.contains { $0.message.contains("big.bin") })

        let listing = try await source.list(remoteFolder)
        XCTAssertEqual(Set(listing.map(\.name)), ["big.bin", "site"])

        let back = work.appending(path: "back")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        queue.clearFinished()
        queue.download(listing, to: back.path(percentEncoded: false), via: source) {}
        try await waitUntilFinished(queue)
        XCTAssertEqual(queue.transfers.map(\.state), [.done, .done])

        XCTAssertEqual(try digest(back.appending(path: "big.bin")), try digest(big))
        XCTAssertEqual(try digest(back.appending(path: "site/index.html")), try digest(site.appending(path: "index.html")))
        XCTAssertEqual(try digest(back.appending(path: "site/css/app.css")), try digest(site.appending(path: "css/app.css")))

        try await source.remove(remoteFolder, isDirectory: true)
        let after = try await source.list("/upload")
        XCTAssertFalse(after.contains { $0.path == remoteFolder }, "Folder delete should be recursive")
    }

    func testCancelStopsTransfer() async throws {
        let big = work.appending(path: "huge.bin")
        try randomData(30_000_000).write(to: big)
        let queue = TransferQueue()
        remoteLeftovers.append(("/upload/huge.bin", false))
        queue.upload(try await localItems([big]), to: "/upload", via: source) {}
        try await Task.sleep(for: .milliseconds(300))
        queue.cancel(queue.transfers[0])
        try await waitUntilFinished(queue)
        XCTAssertEqual(queue.transfers[0].state, .cancelled)
        XCTAssertLessThan(queue.transfers[0].doneBytes, 30_000_000)
    }

    func testReadOnlyFolderExplainsItself() async throws {
        // The chrooted test server's top folder belongs to root, so writing there is refused.
        let file = work.appending(path: "note.txt")
        try Data("hi".utf8).write(to: file)
        let queue = TransferQueue()
        queue.upload(try await localItems([file]), to: "/", via: source) {}
        try await waitUntilFinished(queue)
        XCTAssertEqual(queue.transfers[0].state,
                       .failed(String(localized: "The server doesn't allow this here.", bundle: .main)))
        XCTAssertEqual(ActivityLog.shared.entries.last?.level, .error, "Failures should be logged as errors")
    }

    // MARK: Helpers

    private func localItems(_ urls: [URL]) async throws -> [FileItem] {
        let all = try await LocalFileSource(root: work).list(work.path(percentEncoded: false))
        return urls.compactMap { url in all.first { $0.name == url.lastPathComponent } }
    }

    private func waitUntilFinished(_ queue: TransferQueue, timeout: Duration = .seconds(60)) async throws {
        let deadline = ContinuousClock.now + timeout
        while queue.activeCount > 0 {
            guard ContinuousClock.now < deadline else { return XCTFail("Transfers didn't finish in time") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(100)) // let progress hops land
    }

    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
