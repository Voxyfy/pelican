import XCTest
@testable import Pelican

/// Key sign-in against the Docker test server. Keys are made fresh with ssh-keygen and their
/// public halves added to the container's authorized_keys. Skipped without Docker.
@MainActor
final class KeyAuthTests: XCTestCase {
    private var server = Server(name: "Test", host: "127.0.0.1", port: 2222, username: "pelican", usesKey: true)
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "pelican-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            _ = try await SFTPFileSource.connect(to: server, password: "pelican-test")
        } catch let error as HostKeyError {
            HostKeys.trust(error.presentedKey, host: server.host, port: server.port)
        } catch {
            throw XCTSkip("Test SFTP server not reachable: \(error)")
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testEd25519WithoutPassphrase() async throws {
        let key = try makeKey("plain", type: "ed25519", passphrase: "")
        XCTAssertFalse(try SSHKey.inspect(key))
        let source = try await SFTPFileSource.connect(to: server, credential: .key(key, passphrase: ""))
        let listing = try await source.list("/upload")
        XCTAssertTrue(listing.contains { $0.name == "public_html" })
        await source.disconnect()
    }

    func testEd25519WithPassphrase() async throws {
        let key = try makeKey("locked", type: "ed25519", passphrase: "gaga-kesesi")
        XCTAssertTrue(try SSHKey.inspect(key), "An encrypted key should ask for its passphrase")

        let source = try await SFTPFileSource.connect(to: server, credential: .key(key, passphrase: "gaga-kesesi"))
        await source.disconnect()

        do {
            _ = try await SFTPFileSource.connect(to: server, credential: .key(key, passphrase: "wrong"))
            XCTFail("A wrong passphrase must not sign in")
        } catch let problem as SSHKey.Problem {
            XCTAssertEqual(problem, .wrongPassphrase)
        }
    }

    func testRSA() async throws {
        let key = try makeKey("rsa", type: "rsa", passphrase: "", bits: 3072)
        let source = try await SFTPFileSource.connect(to: server, credential: .key(key, passphrase: ""))
        await source.disconnect()
    }

    func testUnknownKeyIsExplained() async throws {
        // A valid key whose public half was never installed on the server.
        let key = try makeKey("stranger", type: "ed25519", passphrase: "", install: false)
        let connection = Connection()
        await connection.test(server, credential: .key(key, passphrase: ""))
        XCTAssertEqual(connection.testState, .failed(String(
            localized: "The server didn't accept this key. Check that its public key is in authorized_keys.",
            bundle: .main)))
    }

    func testOldPEMFormatIsExplained() throws {
        let key = try makeKey("pem", type: "rsa", passphrase: "", bits: 2048, extra: ["-m", "PEM"], install: false)
        XCTAssertThrowsError(try SSHKey.inspect(key)) { error in
            XCTAssertEqual(error as? SSHKey.Problem, .notOpenSSH)
        }
    }

    /// OpenSSH 10 (see README) takes ed25519 but refuses Citadel's SHA-1 RSA signature,
    /// which should come back as an explanation rather than a generic failure.
    func testModernServer() async throws {
        var modern = server
        modern.port = 2223
        let ed = try makeKey("modern-ed", type: "ed25519", passphrase: "", installOn: .modern)
        let rsa = try makeKey("modern-rsa", type: "rsa", passphrase: "", bits: 3072, installOn: .modern)
        do {
            _ = try await SFTPFileSource.connect(to: modern, credential: .key(ed, passphrase: ""))
        } catch let error as HostKeyError {
            HostKeys.trust(error.presentedKey, host: modern.host, port: modern.port)
        } catch {
            throw XCTSkip("Modern test server not reachable: \(error)")
        }
        let source = try await SFTPFileSource.connect(to: modern, credential: .key(ed, passphrase: ""))
        await source.disconnect()
        do {
            _ = try await SFTPFileSource.connect(to: modern, credential: .key(rsa, passphrase: ""))
            XCTFail("Expected OpenSSH 10 to refuse SHA-1 RSA; if this passes, RSA now works there")
        } catch let problem as SSHKey.Problem {
            XCTAssertEqual(problem, .rsaRefused)
        }
    }

    // MARK: Helpers

    private enum Container {
        case classic, modern
        var name: String { self == .classic ? "pelican-sftp" : "pelican-sshd-modern" }
        var keysFile: String { self == .classic ? "/home/pelican/.ssh/authorized_keys" : "/config/.ssh/authorized_keys" }
        var fixPermissions: String {
            self == .classic
                ? "chown -R pelican:users /home/pelican/.ssh && chmod 700 /home/pelican/.ssh && chmod 600 \(keysFile)"
                : "true"
        }
    }

    private func makeKey(_ name: String, type: String, passphrase: String, bits: Int? = nil,
                         extra: [String] = [], install: Bool = true,
                         installOn container: Container = .classic) throws -> String {
        let path = dir.appending(path: name).path(percentEncoded: false)
        var args = ["-q", "-t", type, "-N", passphrase, "-C", "pelican-test-\(name)", "-f", path] + extra
        if let bits { args += ["-b", String(bits)] }
        try run("/usr/bin/ssh-keygen", args)
        if install {
            let pub = try String(contentsOfFile: path + ".pub", encoding: .utf8)
            let folder = (container.keysFile as NSString).deletingLastPathComponent
            try run("/usr/local/bin/docker", ["exec", "-i", container.name, "sh", "-c",
                "mkdir -p \(folder) && cat >> \(container.keysFile) && \(container.fixPermissions)"], input: pub)
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func run(_ tool: String, _ args: [String], input: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = args
        let pipe = Pipe()
        if input != nil { process.standardInput = pipe }
        try process.run()
        if let input {
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try pipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(tool) failed with status \(process.terminationStatus)")
        }
    }
}
