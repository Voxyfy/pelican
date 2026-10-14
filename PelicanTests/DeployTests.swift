import XCTest
@testable import Pelican

/// Deploy planning and publishing against the SFTP test server, plus Cloudflare requests.
@MainActor
final class DeployTests: XCTestCase {
    private let server = Server(name: "Test", host: "127.0.0.1", port: 2222, username: "pelican")
    private var source: SFTPFileSource!
    private var site: URL!
    private var remoteRoot = ""

    override func setUp() async throws {
        do {
            _ = try await SFTPFileSource.connect(to: server, password: "pelican-test")
        } catch let error as HostKeyError {
            HostKeys.trust(error.presentedKey, host: server.host, port: server.port)
        } catch {
            throw XCTSkip("Test SFTP server not reachable: \(error)")
        }
        source = try await SFTPFileSource.connect(to: server, password: "pelican-test")
        remoteRoot = "/upload/deploy-\(UUID().uuidString.prefix(6))/public_html"
        site = FileManager.default.temporaryDirectory.appending(path: "site-\(UUID().uuidString)")
        for folder in ["css", "img/icons", ".git", "node_modules/lib"] {
            try FileManager.default.createDirectory(at: site.appending(path: folder), withIntermediateDirectories: true)
        }
        try write("index.html", "<h1>v1</h1>")
        try write("css/site.css", "body{}")
        try write("img/icons/a.svg", "<svg/>")
        try write(".git/HEAD", "ref")
        try write("node_modules/lib/x.js", "x")
        try write(".env", "SECRET=1")
        try write("debug.log", "log")
    }

    override func tearDown() async throws {
        try? await source?.remove((remoteRoot as NSString).deletingLastPathComponent, isDirectory: true)
        await source?.disconnect()
        if let site { try? FileManager.default.removeItem(at: site) }
    }

    func testDeploySendsOnlyChangesAndHonorsExcludes() async throws {
        // First deploy: everything except excluded files, folders created first.
        var plan = try await makePlan(manifest: DeployManifest())
        XCTAssertEqual(Set(plan.uploads.map(\.relative)), ["index.html", "css/site.css", "img/icons/a.svg"])
        XCTAssertEqual(plan.foldersToCreate, ["css", "img", "img/icons"])
        try await publish(plan)
        var manifest = plan.manifest
        let sent = try await source.walk(remoteRoot).filter { !$0.isDirectory }.map(\.name)
        XCTAssertEqual(Set(sent), ["index.html", "site.css", "a.svg"])

        // Nothing changed: nothing to send.
        plan = try await makePlan(manifest: manifest)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.unchanged, 3)

        // An edit, a new file, and a file someone deleted on the server.
        try await Task.sleep(for: .seconds(1.1))
        try write("index.html", "<h1>v2 longer</h1>")
        try write("css/new.css", "p{}")
        try await source.remove(remoteRoot + "/img/icons/a.svg", isDirectory: false)
        plan = try await makePlan(manifest: manifest)
        XCTAssertEqual(Set(plan.uploads.map(\.relative)), ["index.html", "css/new.css", "img/icons/a.svg"])
        try await publish(plan)
        manifest = plan.manifest

        // A local deletion only reaches the server when asked for.
        try FileManager.default.removeItem(at: site.appending(path: "css/new.css"))
        plan = try await makePlan(manifest: manifest)
        XCTAssertTrue(plan.deletions.isEmpty)
        plan = try await makePlan(manifest: manifest, deleteRemoved: true)
        XCTAssertEqual(plan.deletions, ["css/new.css"])
        try await publish(plan)
        let css = try await source.list(remoteRoot + "/css").map(\.name)
        XCTAssertEqual(css, ["site.css"])
    }

    func testExcludePatterns() {
        let patterns = DeployTarget.defaultExcludes + ["storage/logs"]
        XCTAssertTrue(DeployPlanner.isExcluded(".git/config", by: patterns))
        XCTAssertTrue(DeployPlanner.isExcluded("a/node_modules/x.js", by: patterns))
        XCTAssertTrue(DeployPlanner.isExcluded(".env.production", by: patterns))
        XCTAssertTrue(DeployPlanner.isExcluded("logs/app.log", by: patterns))
        XCTAssertTrue(DeployPlanner.isExcluded("storage/logs/laravel.txt", by: patterns))
        XCTAssertFalse(DeployPlanner.isExcluded("storage/app/file.txt", by: patterns))
        XCTAssertFalse(DeployPlanner.isExcluded("environment.html", by: patterns))
    }

    func testCloudflarePurgeRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudflareStub.self]
        Cloudflare.session = URLSession(configuration: configuration)
        Cloudflare.apiBase = URL(string: "https://cloudflare.test/client/v4")!
        CloudflareStub.requests = []
        CloudflareStub.reply = #"{"success":true,"errors":[]}"#

        let urls = Cloudflare.urls(for: (1...31).map { "p\($0).html" } + ["blog/index.html"], site: "https://example.com/")
        XCTAssertTrue(urls.contains("https://example.com/blog/"))
        try await Cloudflare.purge(zone: "zone1", token: "tok", urls: urls)
        XCTAssertEqual(CloudflareStub.requests.count, 2, "33 URLs go out in batches of 30")
        XCTAssertEqual(CloudflareStub.requests.first?.url?.path(), "/client/v4/zones/zone1/purge_cache")
        XCTAssertEqual(CloudflareStub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        CloudflareStub.requests = []
        try await Cloudflare.purge(zone: "zone1", token: "tok", urls: nil)
        XCTAssertEqual(CloudflareStub.bodies.last?["purge_everything"] as? Bool, true)

        CloudflareStub.reply = #"{"success":false,"errors":[{"message":"Invalid API Token"}]}"#
        do {
            try await Cloudflare.purge(zone: "zone1", token: "bad", urls: nil)
            XCTFail("A failed purge should throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Invalid API Token")
        }
    }

    // MARK: Helpers

    private func write(_ relative: String, _ text: String) throws {
        try Data(text.utf8).write(to: site.appending(path: relative))
    }

    private func makePlan(manifest: DeployManifest, deleteRemoved: Bool = false) async throws -> DeployPlan {
        try await DeployPlanner.plan(local: site, remote: source, remoteRoot: remoteRoot,
                                     excludes: DeployTarget.defaultExcludes, deleteRemoved: deleteRemoved,
                                     manifest: manifest)
    }

    private func publish(_ plan: DeployPlan) async throws {
        let queue = TransferQueue()
        let transfer = queue.deploy(plan, name: "site", to: remoteRoot, via: source) {}
        while !transfer.state.isFinished { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(transfer.state, .done)
    }
}

/// Records Cloudflare API calls instead of sending them.
final class CloudflareStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var reply = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { Self.bodies.append(json) }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
