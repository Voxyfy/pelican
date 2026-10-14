import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL
import Security

/// A complete FTP server reply: "230 Logged in" or a multi-line "211-…/211 End".
struct FTPReply: Sendable, CustomStringConvertible {
    let code: Int
    let lines: [String]
    var text: String { lines.joined(separator: "\n") }
    var description: String { "\(code) \(text)" }
    var isPreliminary: Bool { (100..<200).contains(code) }
    var isSuccess: Bool { (200..<400).contains(code) }
}

/// An FTP reply that wasn't the one a command expects.
struct FTPError: Error, LocalizedError, Sendable {
    let reply: FTPReply
    var errorDescription: String? { reply.text }
}

/// The control or data connection closed before the exchange finished.
struct FTPConnectionClosed: Error {}

/// Splits control-connection bytes into lines and lines into replies.
final class FTPReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let replies: AsyncThrowingStream<FTPReply, Error>
    private let continuation: AsyncThrowingStream<FTPReply, Error>.Continuation
    private var pending: [UInt8] = []
    private var multiLine: (code: Int, lines: [String])?

    init() {
        (replies, continuation) = AsyncThrowingStream.makeStream()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readBytes(length: buffer.readableBytes) ?? []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            if line.hasSuffix("\r") { line.removeLast() }
            parse(line)
        }
    }

    private func parse(_ line: String) {
        if var open = multiLine {
            if line.hasPrefix("\(open.code) ") {
                open.lines.append(String(line.dropFirst(4)))
                continuation.yield(FTPReply(code: open.code, lines: open.lines))
                multiLine = nil
            } else {
                open.lines.append(line)
                multiLine = open
            }
            return
        }
        guard line.count >= 3, let code = Int(line.prefix(3)) else { return }
        let rest = String(line.dropFirst(4))
        if line.dropFirst(3).first == "-" {
            multiLine = (code, [rest])
        } else {
            continuation.yield(FTPReply(code: code, lines: [rest]))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish(throwing: FTPConnectionClosed())
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}

/// Collects a data connection's bytes until the server closes it.
final class FTPDataHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let chunks: AsyncThrowingStream<ByteBuffer, Error>
    private let continuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation

    init() {
        (chunks, continuation) = AsyncThrowingStream.makeStream()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Many servers end TLS data connections without a close_notify; the data is complete.
        if case NIOSSLError.uncleanShutdown = error {
            continuation.finish()
        } else {
            continuation.finish(throwing: error)
        }
        context.close(promise: nil)
    }
}

/// Decides whether to trust an FTPS certificate: anything macOS trusts for this host name,
/// or a certificate the user accepted before (stored like SSH host keys).
final class FTPCertificateCheck: Sendable {
    let host: String
    let port: Int
    /// Written from the TLS verification queue, read by the client; hence the lock.
    private let rejected = NIOLockedValueBox<HostKeyError?>(nil)
    var rejection: HostKeyError? { rejected.withLockedValue { $0 } }

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// The value stored in known hosts for a certificate.
    static func trustValue(forDER der: Data) -> String {
        "cert " + Data(SHA256.hash(data: der)).base64EncodedString()
    }

    func verify(_ chain: [NIOSSLCertificate], _ promise: EventLoopPromise<NIOSSLVerificationResult>) {
        let ders = chain.compactMap { try? Data($0.toDERBytes()) }
        guard let leaf = ders.first else { return promise.succeed(.failed) }
        let presented = Self.trustValue(forDER: leaf)
        let known = HostKeys.trusted(for: host, port: port)
        if known == presented { return promise.succeed(.certificateVerified) }
        let host = self.host
        let port = self.port
        // Trust evaluation can touch the network (revocation), so keep it off the event loop.
        DispatchQueue.global().async {
            let certificates = ders.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            var trust: SecTrust?
            SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
            if let trust, SecTrustEvaluateWithError(trust, nil) {
                promise.succeed(.certificateVerified)
            } else {
                let error = HostKeyError(host: host, port: port, presentedKey: presented,
                                         changed: known != nil, isCertificate: true)
                self.rejected.withLockedValue { $0 = error }
                promise.succeed(.failed)
            }
        }
    }
}
