import Citadel
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.voxyfy.pelican", category: "connection")

/// The right-hand pane's connection: which server, its file pane, and any pending prompt.
@MainActor @Observable
final class Connection {
    struct HostKeyPrompt {
        let error: HostKeyError
        let server: Server
        let credential: Credential
        /// Whether trusting the key should continue a test or a real connection.
        let isTest: Bool
    }

    enum TestState: Equatable {
        case running
        case succeeded(folder: String)
        case failed(String)
    }

    let favorites = Favorites()
    private let activity = ActivityLog.shared
    private(set) var pane: PaneModel?
    private(set) var server: Server?
    private(set) var connecting: Server?
    var error: String?
    var hostKeyPrompt: HostKeyPrompt?
    var testState: TestState?
    /// A saved server whose password is missing or was refused; the UI opens its editor.
    var needsPassword: Server?
    private var lastError: Error?

    /// Connects a saved server; returns false when its password isn't in Keychain.
    func open(_ server: Server) -> Bool {
        guard let credential = Keychain.credential(for: server) else { return false }
        Task {
            await connect(server, credential: credential)
            if case SSHClientError.allAuthenticationOptionsFailed? = lastError { needsPassword = server }
            if lastError is SSHKey.Problem { needsPassword = server }
        }
        return true
    }

    func save(_ server: Server, credential: Credential) {
        favorites.save(server)
        Keychain.save(credential, for: server)
    }

    func connect(_ server: Server, credential: Credential) async {
        await disconnect()
        connecting = server
        error = nil
        lastError = nil
        defer { connecting = nil }
        activity.info(String(localized: "Connecting to \(server.title)…"))
        do {
            let source = try await Remote.connect(to: server, credential: credential)
            pane = PaneModel(source: source)
            self.server = server
            activity.success(String(localized: "Connected to \(server.title). Opened \(source.startPath)."))
        } catch let rejection as HostKeyError {
            activity.info(rejection.localizedDescription)
            hostKeyPrompt = HostKeyPrompt(error: rejection, server: server, credential: credential, isTest: false)
        } catch {
            log.error("Connect failed: \(String(describing: error), privacy: .public)")
            lastError = error
            self.error = FriendlyError.message(for: error, server: server)
            activity.error(String(localized: "Couldn't connect to \(server.title): \(self.error ?? "")"))
        }
    }

    /// Signs in and opens SFTP, then hangs up, so the user knows the details work before saving.
    func test(_ server: Server, credential: Credential) async {
        log.notice("Testing \(server.host, privacy: .public):\(server.port)")
        testState = .running
        do {
            let source = try await Remote.connect(to: server, credential: credential)
            await source.disconnect()
            log.notice("Test succeeded")
            testState = .succeeded(folder: source.startPath)
            activity.success(String(localized: "Connection test to \(server.title) succeeded."))
        } catch let rejection as HostKeyError {
            log.notice("Test needs host key trust (changed: \(rejection.changed))")
            testState = nil
            hostKeyPrompt = HostKeyPrompt(error: rejection, server: server, credential: credential, isTest: true)
        } catch {
            log.error("Test failed: \(String(describing: error), privacy: .public)")
            let message = FriendlyError.message(for: error, server: server)
            testState = .failed(message)
            activity.error(String(localized: "Connection test to \(server.title) failed: \(message)"))
        }
    }

    /// Called from the alert. Reads the pending prompt itself, so it doesn't matter
    /// whether SwiftUI clears the alert's state before or after running the button.
    func trustPending() async {
        guard let prompt = hostKeyPrompt else {
            log.error("Trust tapped but no host key prompt is pending")
            return
        }
        hostKeyPrompt = nil
        log.notice("Trusting host key for \(prompt.error.host, privacy: .public):\(prompt.error.port)")
        HostKeys.trust(prompt.error.presentedKey, host: prompt.error.host, port: prompt.error.port)
        activity.info(String(localized: "Trusted \(prompt.error.host) with key \(HostKeys.fingerprint(prompt.error.presentedKey))."))
        let saved = HostKeys.trusted(for: prompt.error.host, port: prompt.error.port) == prompt.error.presentedKey
        log.notice("Host key saved: \(saved), continuing \(prompt.isTest ? "test" : "connect", privacy: .public)")
        if prompt.isTest {
            await test(prompt.server, credential: prompt.credential)
        } else {
            await connect(prompt.server, credential: prompt.credential)
        }
    }

    func disconnect() async {
        if let source = pane?.source as? any RemoteSource {
            await source.disconnect()
            activity.info(String(localized: "Disconnected from \(source.displayName)."))
        }
        pane = nil
        server = nil
    }
}

extension Connection {
    /// Password sign-in, kept for callers and tests that don't deal with keys.
    func connect(_ server: Server, password: String) async { await connect(server, credential: .password(password)) }
    func test(_ server: Server, password: String) async { await test(server, credential: .password(password)) }
}
