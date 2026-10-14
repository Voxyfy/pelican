import XCTest
@testable import Pelican

/// "Test Connection" against the Docker test server (see README). Skipped when it isn't running.
@MainActor
final class ConnectionTestTests: XCTestCase {
    private let server = Server(name: "Test", host: "127.0.0.1", port: 2222, username: "pelican")

    override func setUp() async throws {
        // Trust the test server's key up front, as if the user had accepted it once.
        do {
            _ = try await SFTPFileSource.connect(to: server, password: "pelican-test")
        } catch let error as HostKeyError {
            HostKeys.trust(error.presentedKey, host: server.host, port: server.port)
        } catch {
            throw XCTSkip("Test SFTP server not reachable: \(error)")
        }
    }

    func testRightPasswordSucceedsAndHangsUp() async {
        let connection = Connection()
        await connection.test(server, password: "pelican-test")
        XCTAssertEqual(connection.testState, .succeeded(folder: "/"))
        XCTAssertNil(connection.pane, "A test must not leave a connection open")
    }

    func testWrongPasswordFails() async {
        let connection = Connection()
        await connection.test(server, password: "wrong")
        guard case .failed(let message) = connection.testState else {
            return XCTFail("Expected failure, got \(String(describing: connection.testState))")
        }
        // Compare through the app's catalog so the test passes in any system language.
        XCTAssertEqual(message, String(localized: "The user name or password is incorrect.", bundle: .main))
    }

    func testClosedPortIsExplained() async {
        var closed = server
        closed.port = 2299
        let connection = Connection()
        await connection.test(closed, password: "pelican-test")
        guard case .failed(let message) = connection.testState else {
            return XCTFail("Expected failure, got \(String(describing: connection.testState))")
        }
        print("CLOSED_PORT_MESSAGE: \(message)")
        XCTAssertTrue(message.contains("2299"), message)
    }

    func testUnknownHostIsExplained() async {
        var missing = server
        missing.host = "no-such-host.invalid"
        let connection = Connection()
        await connection.test(missing, password: "pelican-test")
        guard case .failed(let message) = connection.testState else {
            return XCTFail("Expected failure, got \(String(describing: connection.testState))")
        }
        print("UNKNOWN_HOST_MESSAGE: \(message)")
        XCTAssertTrue(message.contains("no-such-host.invalid"), message)
    }
}
