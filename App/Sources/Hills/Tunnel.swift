import AgentKit
import Citadel
import Foundation
import Network
import NIOCore
import NIOSSH

/// SSH local port forwarding: a port on the phone's own loopback that leads, through a 远山 host's SSH connection,
/// to a port on that host's loopback. An MCP service that listens only on the far computer's 127.0.0.1 is reached
/// this way without opening any port to the internet.
actor Tunnels {
    static let shared = Tunnels()

    private final class Open {
        let listener: NWListener
        let port: Int
        var client: SSHClient?
        init(listener: NWListener, port: Int) {
            self.listener = listener
            self.port = port
        }
    }

    private var open: [String: Open] = [:]

    /// The address to use on the phone for a service at `remote` (like http://127.0.0.1:8931/mcp) on `host`.
    func url(for remote: String, through host: Hills.Host) async throws -> String {
        guard var parts = URLComponents(string: remote) else { throw ProviderError("看不懂这个远端地址：\(remote)") }
        let remotePort = parts.port ?? (parts.scheme == "https" ? 443 : 80)
        let target = parts.host ?? "127.0.0.1"
        let key = "\(host.id)|\(target):\(remotePort)"
        let local = try await localPort(key: key, host: host, targetHost: target, targetPort: remotePort)
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.port = local
        guard let url = parts.string else { throw ProviderError("隧道地址拼不出来") }
        return url
    }

    /// Closes every tunnel (when the app goes away or a host is removed).
    func closeAll() async {
        for tunnel in open.values {
            tunnel.listener.cancel()
            try? await tunnel.client?.close()
        }
        open = [:]
    }

    private func localPort(key: String, host: Hills.Host, targetHost: String, targetPort: Int) async throws -> Int {
        if let kept = open[key], kept.listener.state == .ready { return kept.port }
        if let stale = open.removeValue(forKey: key) {
            stale.listener.cancel()
            try? await stale.client?.close()
        }
        // The same port number as on the far side when it is free, so the service sees the Host it expects.
        let listener = try Self.listen(preferring: targetPort)
        let port = try await Self.ready(listener)
        let tunnel = Open(listener: listener, port: port)
        open[key] = tunnel
        listener.newConnectionHandler = { connection in
            Task { await self.carry(connection, key: key, host: host, targetHost: targetHost, targetPort: targetPort) }
        }
        return port
    }

    private static func listen(preferring port: Int) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        if let wanted = NWEndpoint.Port(rawValue: UInt16(clamping: port)), let listener = try? NWListener(using: parameters, on: wanted) {
            return listener
        }
        return try NWListener(using: parameters, on: .any)
    }

    private static func ready(_ listener: NWListener) async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let once = OnceBox()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: ProviderError("隧道关掉了")) }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// One connection from the phone: a fresh SSH channel to the far port, bytes carried both ways until either side closes.
    private func carry(_ connection: NWConnection, key: String, host: Hills.Host, targetHost: String, targetPort: Int) async {
        connection.start(queue: .global(qos: .userInitiated))
        do {
            let client = try await sshClient(key: key, host: host)
            let settings = SSHChannelType.DirectTCPIP(targetHost: targetHost, targetPort: targetPort, originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
            let channel = try await client.createDirectTCPIPChannel(using: settings) { channel in
                channel.pipeline.addHandler(Relay(connection))
            }
            Self.pump(connection, into: channel)
        } catch {
            Diag.note("隧道连不上 \(host.name) 的 \(targetHost):\(targetPort)：\(error.localizedDescription)")
            if let kept = open[key] { kept.client = nil }
            connection.cancel()
        }
    }

    private func sshClient(key: String, host: Hills.Host) async throws -> SSHClient {
        if let client = open[key]?.client, client.isConnected { return client }
        let client = try await Hills.connect(host)
        open[key]?.client = client
        return client
    }

    /// Phone → far side.
    private nonisolated static func pump(_ connection: NWConnection, into channel: Channel) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            if let data, !data.isEmpty {
                channel.writeAndFlush(ByteBuffer(bytes: data), promise: nil)
            }
            if complete || error != nil {
                channel.close(promise: nil)
                return
            }
            Tunnels.pump(connection, into: channel)
        }
    }

    /// Far side → phone.
    private final class Relay: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            connection.send(content: Data(buffer.readableBytesView), completion: .contentProcessed { _ in })
        }

        func channelInactive(context: ChannelHandlerContext) {
            connection.cancel()
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            connection.cancel()
            context.close(promise: nil)
        }
    }

    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
