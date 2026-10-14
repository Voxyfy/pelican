import XCTest
@testable import Pelican

/// Real servers on the internet: Rebex's public, read-only demo (demo / password).
/// Catches what local containers don't, like strict SSH algorithm negotiation. Skipped offline.
@MainActor
final class PublicServerTests: XCTestCase {
    private func connect(_ kind: TransferProtocol, port: Int) async throws -> any RemoteSource {
        var server = Server(name: "Rebex", host: "test.rebex.net", port: port, username: "demo")
        server.kind = kind
        for attempt in 0..<2 {
            do {
                return try await Remote.connect(to: server, credential: .password("password"))
            } catch let error as HostKeyError where attempt == 0 {
                HostKeys.trust(error.presentedKey, host: error.host, port: error.port)
            } catch let error as URLError {
                throw XCTSkip("Offline: \(error)")
            }
        }
        throw XCTSkip("Couldn't reach test.rebex.net")
    }

    func testSFTPWithStrictServer() async throws {
        let source = try await connect(.sftp, port: 22)
        let names = try await source.list("/").map(\.name)
        XCTAssertTrue(names.contains("readme.txt"), "\(names)")
        await source.disconnect()
    }

    func testFTPDownload() async throws {
        let source = try await connect(.ftp, port: 21)
        let local = FileManager.default.temporaryDirectory.appending(path: "rebex-readme-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: local) }
        try await source.download(from: "/readme.txt", size: 0, to: local) { _ in }
        let text = try String(contentsOf: local, encoding: .utf8)
        XCTAssertTrue(text.lowercased().contains("rebex"))
        await source.disconnect()
    }

    /// Rebex, like ProFTPD, vsftpd and FileZilla Server, only accepts FTPS data connections
    /// that resume the control connection's TLS session.
    func testFTPSWithSessionReuse() async throws {
        let source = try await connect(.ftps, port: 21)
        let names = try await source.list("/").map(\.name)
        XCTAssertTrue(names.contains("readme.txt"), "\(names)")
        let local = FileManager.default.temporaryDirectory.appending(path: "rebex-ftps-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: local) }
        try await source.download(from: "/readme.txt", size: 0, to: local) { _ in }
        XCTAssertTrue(try String(contentsOf: local, encoding: .utf8).lowercased().contains("rebex"))
        await source.disconnect()
    }
}
