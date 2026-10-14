import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// One FTP control connection. FTP runs one command at a time, so every exchange takes
/// the connection's lock; listing and transfers use separate clients to overlap.
actor FTPClient {
    let host: String
    let port: Int
    let usesTLS: Bool

    private let channel: Channel
    private var replies: AsyncThrowingStream<FTPReply, Error>.AsyncIterator
    private let check: FTPCertificateCheck
    private var supportsMLSD = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init(host: String, port: Int, usesTLS: Bool, channel: Channel, handler: FTPReplyHandler,
                 check: FTPCertificateCheck) {
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
        self.channel = channel
        self.replies = handler.replies.makeAsyncIterator()
        self.check = check
    }

    // MARK: Connecting

    static func connect(host: String, port: Int, tls: Bool, user: String, password: String) async throws -> FTPClient {
        let handler = FTPReplyHandler()
        let check = FTPCertificateCheck(host: host, port: port)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelInitializer { $0.pipeline.addHandler(handler) }
            .connect(host: host, port: port)
            .get()
        let client = FTPClient(host: host, port: port, usesTLS: tls, channel: channel, handler: handler, check: check)
        do {
            try await client.start(user: user, password: password)
        } catch {
            try? await channel.close()
            throw check.rejection ?? error
        }
        return client
    }

    private func start(user: String, password: String) async throws {
        try await expect(nil, 200..<300) // greeting
        if usesTLS {
            try await expect("AUTH TLS", 200..<300)
            let tls = try makeTLSHandler()
            try await channel.pipeline.addHandler(tls, position: .first).get()
            try await expect("PBSZ 0", 200..<300)
            try await expect("PROT P", 200..<300)
        }
        let userReply = try await command("USER \(user)")
        if userReply.code == 331 {
            try await expect("PASS \(password)", 200..<300)
        } else if !userReply.isSuccess {
            throw FTPError(reply: userReply)
        }
        _ = try? await command("OPTS UTF8 ON")
        try await expect("TYPE I", 200..<300)
        let features = try await command("FEAT")
        supportsMLSD = features.lines.contains { $0.uppercased().contains("MLST") }
    }

    private func makeTLSHandler() throws -> NIOSSLClientHandler {
        var configuration = TLSConfiguration.makeClientConfiguration()
        // The custom callback checks the chain and host name with macOS trust (or the user's
        // earlier approval), so NIOSSL mustn't reject a user-approved certificate on the name.
        configuration.certificateVerification = .noHostnameVerification
        let context = try NIOSSLContext(configuration: configuration)
        let isAddress = host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        let check = self.check
        return try NIOSSLClientHandler(context: context, serverHostname: isAddress ? nil : host,
                                       customVerificationCallback: { check.verify($0, $1) })
    }

    func quit() async {
        await withLock { _ = try? await command("QUIT") }
        try? await channel.close()
    }

    // MARK: Commands

    func currentDirectory() async throws -> String {
        try await withLock {
            let reply = try await expect("PWD", 200..<300)
            // 257 "/home/user" is the current directory
            let parts = reply.text.split(separator: "\"", omittingEmptySubsequences: false)
            return parts.count >= 2 ? String(parts[1]) : "/"
        }
    }

    func list(_ path: String) async throws -> [FileItem] {
        try await withLock {
            let data = try await openData()
            let reply = try await command(supportsMLSD ? "MLSD \(path)" : "LIST -a \(path)")
            guard reply.isPreliminary || reply.isSuccess else {
                try? await data.channel.close()
                throw FTPError(reply: reply)
            }
            var bytes: [UInt8] = []
            for try await var chunk in data.handler.chunks {
                bytes += chunk.readBytes(length: chunk.readableBytes) ?? []
            }
            if reply.isPreliminary { try await expect(nil, 200..<300) }
            let text = String(decoding: bytes, as: UTF8.self)
            return supportsMLSD ? FTPListing.mlsd(text, in: path) : FTPListing.unix(text, in: path)
        }
    }

    func makeDirectory(_ path: String) async throws {
        try await withLock { try await expect("MKD \(path)", 200..<300) }
    }

    func isDirectory(_ path: String) async -> Bool {
        await withLock { (try? await command("CWD \(path)"))?.isSuccess ?? false }
    }

    func removeFile(_ path: String) async throws {
        try await withLock { try await expect("DELE \(path)", 200..<300) }
    }

    func removeDirectory(_ path: String) async throws {
        try await withLock { try await expect("RMD \(path)", 200..<300) }
    }

    func rename(_ from: String, to: String) async throws {
        try await withLock {
            try await expect("RNFR \(from)", 300..<400)
            try await expect("RNTO \(to)", 200..<300)
        }
    }

    func store(from local: URL, to remotePath: String, progress: @Sendable (Int64) -> Void) async throws {
        try await withLock {
            let input = try FileHandle(forReadingFrom: local)
            defer { try? input.close() }
            let data = try await openData()
            let reply = try await command("STOR \(remotePath)")
            guard reply.isPreliminary else {
                try? await data.channel.close()
                throw FTPError(reply: reply)
            }
            do {
                while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try await data.channel.writeAndFlush(ByteBuffer(bytes: chunk))
                    progress(Int64(chunk.count))
                }
                try await data.channel.close()
            } catch {
                try? await data.channel.close()
                throw error
            }
            try await expect(nil, 200..<300)
        }
    }

    func retrieve(_ remotePath: String, to local: URL, progress: @Sendable (Int64) -> Void) async throws {
        try await withLock {
            FileManager.default.createFile(atPath: local.path(percentEncoded: false), contents: nil)
            let output = try FileHandle(forWritingTo: local)
            defer { try? output.close() }
            let data = try await openData()
            let reply = try await command("RETR \(remotePath)")
            guard reply.isPreliminary else {
                try? await data.channel.close()
                throw FTPError(reply: reply)
            }
            do {
                for try await var chunk in data.handler.chunks {
                    try Task.checkCancellation()
                    let bytes = chunk.readableBytes
                    output.write(Data(chunk.readBytes(length: bytes) ?? []))
                    progress(Int64(bytes))
                }
            } catch {
                try? await data.channel.close()
                throw error
            }
            try await expect(nil, 200..<300)
        }
    }

    // MARK: Plumbing

    private struct DataConnection {
        let channel: Channel
        let handler: FTPDataHandler
    }

    /// Passive mode: ask the server for a port and connect to it. The address in a PASV
    /// reply is often a private one behind NAT, so the control connection's host is used.
    private func openData() async throws -> DataConnection {
        var dataPort: Int?
        if let reply = try? await command("EPSV"), reply.code == 229 {
            // 229 Entering Extended Passive Mode (|||30001|)
            let digits = reply.text.split(separator: "|").compactMap { Int($0) }
            dataPort = digits.last
        }
        if dataPort == nil {
            let reply = try await expect("PASV", 200..<300)
            // 227 Entering Passive Mode (127,0,0,1,117,49)
            let inside = reply.text.split(separator: "(").last?.split(separator: ")").first ?? ""
            let numbers = inside.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 6 else { throw FTPError(reply: reply) }
            dataPort = numbers[4] * 256 + numbers[5]
        }
        guard let dataPort else { throw FTPConnectionClosed() }
        let handler = FTPDataHandler()
        let tls = usesTLS ? try makeTLSHandler() : nil
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                if let tls {
                    return channel.pipeline.addHandlers([tls, handler])
                }
                return channel.pipeline.addHandler(handler)
            }
            .connect(host: host, port: dataPort)
            .get()
        return DataConnection(channel: channel, handler: handler)
    }

    /// Sends a command (or nothing, to read a reply that's still coming) and returns the reply.
    private func command(_ line: String?) async throws -> FTPReply {
        if let line {
            try await channel.writeAndFlush(ByteBuffer(string: line + "\r\n"))
        }
        // Iterators share the stream's storage, so advancing a copy advances the stream.
        var iterator = replies
        let next = try await iterator.next(isolation: self)
        replies = iterator
        guard let reply = next else { throw FTPConnectionClosed() }
        return reply
    }

    @discardableResult
    private func expect(_ line: String?, _ codes: Range<Int>) async throws -> FTPReply {
        let reply = try await command(line)
        guard codes.contains(reply.code) else { throw FTPError(reply: reply) }
        return reply
    }

    /// Actors let other calls in while one awaits; this keeps a whole exchange together.
    private func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
