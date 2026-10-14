import XCTest
@testable import Pelican

/// Runs against the Docker test server (see README). Skipped when it isn't running.
final class SFTPFileSourceTests: XCTestCase {
    private let server = Server(name: "Test", host: "127.0.0.1", port: 2222, username: "pelican")
    private let password = "pelican-test"

    @MainActor
    func testUnknownHostKeyIsRejectedThenTrusted() async throws {
        UserDefaults.standard.removeObject(forKey: "knownHosts")
        do {
            _ = try await SFTPFileSource.connect(to: server, password: password)
            XCTFail("First connection should ask to trust the host key")
        } catch let error as HostKeyError {
            XCTAssertFalse(error.changed)
            XCTAssertTrue(HostKeys.fingerprint(error.presentedKey).hasPrefix("SHA256:"))
            HostKeys.trust(error.presentedKey, host: server.host, port: server.port)
        } catch {
            throw XCTSkip("Test SFTP server not reachable: \(error)")
        }

        let source = try await SFTPFileSource.connect(to: server, password: password)
        defer { Task { await source.disconnect() } }
        // atmoz/sftp chroots the user into their home, so home is "/".
        XCTAssertEqual(source.startPath, "/")

        let upload = try await source.list("/upload")
        XCTAssertEqual(Set(upload.map(\.name)), ["public_html", "logs", ".htaccess"])
        XCTAssertTrue(upload.first { $0.name == "public_html" }!.isDirectory)

        let logs = try await source.list("/upload/logs")
        XCTAssertEqual(logs.first?.size, 2_000_000)
    }

    @MainActor
    func testChangedHostKeyIsRefused() async throws {
        HostKeys.trust("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl",
                       host: server.host, port: server.port)
        do {
            _ = try await SFTPFileSource.connect(to: server, password: password)
            XCTFail("A different host key must not connect")
        } catch let error as HostKeyError {
            XCTAssertTrue(error.changed)
        } catch {
            throw XCTSkip("Test SFTP server not reachable: \(error)")
        }
        UserDefaults.standard.removeObject(forKey: "knownHosts")
    }
}
