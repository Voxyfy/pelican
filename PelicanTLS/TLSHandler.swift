import CNIOBoringSSL
import Foundation
import NIOConcurrencyHelpers
import NIOCore

// A small TLS client on BoringSSL, because NIOSSL can't resume a session on another
// connection. FTPS servers (ProFTPD, vsftpd, FileZilla Server) require exactly that: each data
// connection must reuse the control connection's TLS session.
//
// Kept in its own module: the app also links swift-crypto's copy of BoringSSL, and importing
// both into one module makes their C headers collide.

private let handlerIndex = CNIOBoringSSL_SSL_get_ex_new_index(0, nil, nil, nil, nil)

/// What a TLS connection failed with.
public struct TLSHandlerError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// The TLS settings and the most recent session, shared by a control connection and its data
/// connections so that the data connections resume the control connection's session.
public final class TLSSessionGroup: @unchecked Sendable {
    /// Called with the server's certificate chain (DER, leaf first); answer true to trust it.
    public typealias Verifier = @Sendable (_ chain: [Data], _ done: @escaping @Sendable (Bool) -> Void) -> Void

    let context: OpaquePointer
    let serverName: String?
    let verify: Verifier
    private let lock = NIOLock()
    private var session: OpaquePointer?

    public init(serverName: String?, verify: @escaping Verifier) {
        context = CNIOBoringSSL_SSL_CTX_new(CNIOBoringSSL_TLS_client_method())!
        self.serverName = serverName
        self.verify = verify
        CNIOBoringSSL_SSL_CTX_set_min_proto_version(context, UInt16(TLS1_2_VERSION))
        // Keep sessions ourselves (no internal cache); BoringSSL hands each new one to the callback,
        // including TLS 1.3 tickets that arrive after the handshake.
        CNIOBoringSSL_SSL_CTX_set_session_cache_mode(context, Int32(SSL_SESS_CACHE_CLIENT | SSL_SESS_CACHE_NO_INTERNAL))
        CNIOBoringSSL_SSL_CTX_sess_set_new_cb(context) { ssl, session in
            guard let ssl, let session else { return 0 }
            TLSHandler.owner(of: ssl).group.keep(session)
            return 1 // we own the reference now
        }
    }

    deinit {
        if let session { CNIOBoringSSL_SSL_SESSION_free(session) }
        CNIOBoringSSL_SSL_CTX_free(context)
    }

    fileprivate func keep(_ new: OpaquePointer) {
        lock.withLock {
            if let session { CNIOBoringSSL_SSL_SESSION_free(session) }
            session = new
        }
    }

    /// Hands `ssl` the latest session to resume (SSL_set_session takes its own reference).
    fileprivate func offerSession(to ssl: OpaquePointer) {
        lock.withLock {
            if let session { CNIOBoringSSL_SSL_set_session(ssl, session) }
        }
    }

    public var hasSession: Bool { lock.withLock { session != nil } }
}

/// Encrypts a channel with TLS. Writes made before the handshake finishes wait for it.
public final class TLSHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    let group: TLSSessionGroup
    private let ssl: OpaquePointer
    private let readBIO: UnsafeMutablePointer<BIO>
    private let writeBIO: UnsafeMutablePointer<BIO>
    private var context: ChannelHandlerContext?
    private var handshakeDone = false
    private var closing = false
    private var pending: [(ByteBuffer, EventLoopPromise<Void>?)] = []
    private enum Verification { case idle, waiting, finished(Bool) }
    private var verification = Verification.idle

    /// - Parameter resume: offer the group's latest session, as a data connection must.
    public init(group: TLSSessionGroup, resume: Bool) {
        self.group = group
        ssl = CNIOBoringSSL_SSL_new(group.context)!
        readBIO = CNIOBoringSSL_BIO_new(CNIOBoringSSL_BIO_s_mem())!
        writeBIO = CNIOBoringSSL_BIO_new(CNIOBoringSSL_BIO_s_mem())!
        CNIOBoringSSL_SSL_set_bio(ssl, readBIO, writeBIO) // ssl owns both BIOs from here
        CNIOBoringSSL_SSL_set_connect_state(ssl)
        if let name = group.serverName { CNIOBoringSSL_SSL_set_tlsext_host_name(ssl, name) }
        if resume { group.offerSession(to: ssl) }
        CNIOBoringSSL_SSL_set_ex_data(ssl, handlerIndex, Unmanaged.passUnretained(self).toOpaque())
        CNIOBoringSSL_SSL_set_custom_verify(ssl, SSL_VERIFY_PEER) { ssl, alert in
            TLSHandler.owner(of: ssl!).verifyPeer(alert: alert)
        }
    }

    deinit { CNIOBoringSSL_SSL_free(ssl) }

    fileprivate static func owner(of ssl: OpaquePointer) -> TLSHandler {
        Unmanaged<TLSHandler>.fromOpaque(CNIOBoringSSL_SSL_get_ex_data(ssl, handlerIndex)!).takeUnretainedValue()
    }

    /// True once the handshake resumed an earlier session instead of starting a new one.
    public var resumedSession: Bool { CNIOBoringSSL_SSL_session_reused(ssl) == 1 }

    // MARK: Channel events

    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isActive { advance(context) }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    public func channelActive(context: ChannelHandlerContext) {
        advance(context)
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        failPending(TLSHandlerError(description: "connection closed"))
        context.fireChannelInactive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        buffer.withUnsafeReadableBytes { bytes in
            _ = CNIOBoringSSL_BIO_write(readBIO, bytes.baseAddress, Int32(bytes.count))
        }
        advance(context)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        guard handshakeDone else {
            pending.append((buffer, promise))
            return
        }
        encrypt(buffer, promise: promise, context: context)
    }

    public func flush(context: ChannelHandlerContext) {
        context.flush()
    }

    public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if handshakeDone, !closing, mode == .all {
            closing = true
            CNIOBoringSSL_SSL_shutdown(ssl) // queues close_notify
            sendCiphertext(context, promise: nil)
            context.flush()
        }
        context.close(mode: mode, promise: promise)
    }

    // MARK: TLS

    /// Runs the handshake as far as it can, then decrypts whatever has arrived.
    private func advance(_ context: ChannelHandlerContext) {
        if !handshakeDone {
            let result = CNIOBoringSSL_SSL_do_handshake(ssl)
            if result == 1 {
                handshakeDone = true
                let waiting = pending
                pending = []
                for (buffer, promise) in waiting { encrypt(buffer, promise: promise, context: context) }
            } else {
                let error = CNIOBoringSSL_SSL_get_error(ssl, result)
                if ![SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE, SSL_ERROR_WANT_CERTIFICATE_VERIFY].contains(error) {
                    sendCiphertext(context, promise: nil) // the alert, if any
                    context.flush()
                    return fail(context, Self.lastError(fallback: "handshake failed (\(error))"))
                }
            }
        }
        if handshakeDone { decrypt(context) }
        sendCiphertext(context, promise: nil)
        context.flush()
    }

    private func decrypt(_ context: ChannelHandlerContext) {
        var scratch = [UInt8](repeating: 0, count: 16 * 1024)
        var readAny = false
        while true {
            let count = CNIOBoringSSL_SSL_read(ssl, &scratch, Int32(scratch.count))
            if count > 0 {
                var out = context.channel.allocator.buffer(capacity: Int(count))
                out.writeBytes(scratch[0..<Int(count)])
                context.fireChannelRead(wrapInboundOut(out))
                readAny = true
                continue
            }
            let error = CNIOBoringSSL_SSL_get_error(ssl, count)
            if error == SSL_ERROR_ZERO_RETURN {
                // The server said close_notify. Many FTP servers then wait for ours before closing
                // the socket (and before sending "226"), so answer and close our side.
                if !closing {
                    closing = true
                    CNIOBoringSSL_SSL_shutdown(ssl)
                    sendCiphertext(context, promise: nil)
                    context.flush()
                    context.close(promise: nil)
                }
                break
            }
            if error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE { break }
            fail(context, Self.lastError(fallback: "read failed (\(error))"))
            break
        }
        if readAny { context.fireChannelReadComplete() }
    }

    private func encrypt(_ buffer: ByteBuffer, promise: EventLoopPromise<Void>?, context: ChannelHandlerContext) {
        let written = buffer.withUnsafeReadableBytes { bytes -> Int32 in
            guard bytes.count > 0 else { return 0 }
            return CNIOBoringSSL_SSL_write(ssl, bytes.baseAddress, Int32(bytes.count))
        }
        if buffer.readableBytes > 0, written <= 0 {
            promise?.fail(Self.lastError(fallback: "write failed"))
            return
        }
        sendCiphertext(context, promise: promise)
    }

    /// Moves encrypted bytes from BoringSSL to the socket.
    private func sendCiphertext(_ context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        let available = Int(CNIOBoringSSL_BIO_pending(writeBIO))
        guard available > 0 else {
            promise?.succeed(())
            return
        }
        var out = context.channel.allocator.buffer(capacity: available)
        out.writeWithUnsafeMutableBytes(minimumWritableBytes: available) { bytes in
            Int(CNIOBoringSSL_BIO_read(writeBIO, bytes.baseAddress, Int32(available)))
        }
        context.write(wrapOutboundOut(out), promise: promise)
    }

    private func verifyPeer(alert: UnsafeMutablePointer<UInt8>?) -> ssl_verify_result_t {
        switch verification {
        case .finished(let trusted):
            if !trusted { alert?.pointee = UInt8(SSL_AD_BAD_CERTIFICATE) }
            return trusted ? ssl_verify_ok : ssl_verify_invalid
        case .waiting:
            return ssl_verify_retry
        case .idle:
            guard let loop = context?.eventLoop else { return ssl_verify_invalid }
            verification = .waiting
            group.verify(peerChain()) { trusted in
                loop.execute {
                    self.verification = .finished(trusted)
                    if let context = self.context { self.advance(context) }
                }
            }
            return ssl_verify_retry
        }
    }

    private func peerChain() -> [Data] {
        guard let stack = CNIOBoringSSL_SSL_get0_peer_certificates(ssl) else { return [] }
        return (0..<CNIOBoringSSL_sk_CRYPTO_BUFFER_num(stack)).compactMap { index in
            guard let buffer = CNIOBoringSSL_sk_CRYPTO_BUFFER_value(stack, index),
                  let bytes = CNIOBoringSSL_CRYPTO_BUFFER_data(buffer) else { return nil }
            return Data(bytes: bytes, count: CNIOBoringSSL_CRYPTO_BUFFER_len(buffer))
        }
    }

    private func fail(_ context: ChannelHandlerContext, _ error: Error) {
        failPending(error)
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending = []
        for (_, promise) in waiting { promise?.fail(error) }
    }

    private static func lastError(fallback: String) -> TLSHandlerError {
        let code = CNIOBoringSSL_ERR_get_error()
        guard code != 0 else { return TLSHandlerError(description: fallback) }
        var text = [CChar](repeating: 0, count: 256)
        CNIOBoringSSL_ERR_error_string_n(code, &text, text.count)
        CNIOBoringSSL_ERR_clear_error()
        return TLSHandlerError(description: String(cString: text))
    }
}
