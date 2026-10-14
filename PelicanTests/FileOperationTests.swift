import XCTest
@testable import Pelican

/// Rename, new folder, move, copy and delete, on the Docker test server and on a temporary local folder.
@MainActor
final class FileOperationTests: XCTestCase {
    private let server = Server(name: "Test", host: "127.0.0.1", port: 2222, username: "pelican")
    private var source: SFTPFileSource!
    private var base = ""

    override func setUp() async throws {
        do {
            _ = try await SFTPFileSource.connect(to: server, password: "pelican-test")
        } catch let error as HostKeyError {
            HostKeys.trust(error.presentedKey, host: server.host, port: server.port)
        } catch {
            throw XCTSkip("Test SFTP server not reachable: \(error)")
        }
        source = try await SFTPFileSource.connect(to: server, password: "pelican-test")
        base = "/upload/ops-\(UUID().uuidString.prefix(8))"
        try await source.makeDirectory(base)
    }

    override func tearDown() async throws {
        try? await source?.remove(base, isDirectory: true)
        await source?.disconnect()
    }

    func testServerFolderRenameMoveDelete() async throws {
        let pane = PaneModel(source: source)
        await pane.navigate(to: base)

        await pane.newFolder()
        XCTAssertNil(pane.operationError)
        let untitled = String(localized: "untitled folder", bundle: .main)
        XCTAssertEqual(pane.renaming, "\(base)/\(untitled)", "New folder should start renaming")

        let folder = try XCTUnwrap(pane.rows.first { $0.item.name == untitled }?.item)
        await pane.rename(folder, to: "assets")
        XCTAssertEqual(pane.rows.map(\.item.name), ["assets"])

        // Upload a file next to it, then move it into the folder.
        let local = FileManager.default.temporaryDirectory.appending(path: "logo-\(UUID().uuidString).txt")
        try Data("pelican".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try await source.upload(from: local, to: "\(base)/logo.txt") { _ in }
        await pane.reloadAll()
        let logo = try XCTUnwrap(pane.rows.first { $0.item.name == "logo.txt" }?.item)
        await pane.move([logo], to: "\(base)/assets")
        XCTAssertNil(pane.operationError)
        let inAssets = try await source.list("\(base)/assets").map(\.name)
        XCTAssertEqual(inAssets, ["logo.txt"])

        // A folder can't be moved into itself.
        let assets = try XCTUnwrap(pane.rows.first { $0.item.name == "assets" }?.item)
        await pane.move([assets], to: "\(base)/assets")
        let top = try await source.list(base).map(\.name)
        XCTAssertEqual(top, ["assets"])

        // Renaming onto an existing name is refused before touching the server.
        await pane.newFolder()
        pane.renaming = nil
        let second = try XCTUnwrap(pane.rows.first { $0.item.name == untitled }?.item)
        await pane.rename(second, to: "assets")
        XCTAssertNotNil(pane.operationError)
        pane.operationError = nil

        await pane.delete(pane.rows.map(\.item))
        XCTAssertNil(pane.operationError)
        let left = try await source.list(base)
        XCTAssertTrue(left.isEmpty, "Delete should remove folders with their contents")
    }

    func testServerCopyGoesThroughQueueWithFreeName() async throws {
        let local = FileManager.default.temporaryDirectory.appending(path: "page-\(UUID().uuidString).html")
        try Data(repeating: 7, count: 100_000).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try await source.upload(from: local, to: "\(base)/page.html") { _ in }

        let pane = PaneModel(source: source)
        await pane.navigate(to: base)
        let page = try XCTUnwrap(pane.rows.first?.item)
        let name = pane.freeName(for: page.name, in: base, copy: true)
        let stem = "page"
        XCTAssertEqual(name, String(localized: "\(stem) copy", bundle: .main) + ".html")

        let queue = TransferQueue()
        queue.copy([(page, name)], to: base, via: source) {}
        while queue.activeCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(queue.transfers.first?.state, .done)
        let copied = try await source.list(base).first { $0.name == name }
        XCTAssertEqual(copied?.size, 100_000)
    }

    func testLocalCopyAndMove() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pelican-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "a.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let pane = PaneModel(source: LocalFileSource(root: root))
        await pane.reload()
        let file = try XCTUnwrap(pane.rows.first { $0.item.name == "a.txt" }?.item)
        await pane.copyInPlace([file], to: pane.path)
        let stem = "a"
        let copyName = String(localized: "\(stem) copy", bundle: .main) + ".txt"
        XCTAssertTrue(pane.rows.contains { $0.item.name == copyName }, "\(pane.rows.map(\.item.name))")

        await pane.move([file], to: root.appending(path: "docs").path(percentEncoded: false))
        XCTAssertNil(pane.operationError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "docs/a.txt").path(percentEncoded: false)))
    }
}
