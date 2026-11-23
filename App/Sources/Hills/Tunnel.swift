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
        var connectingClient: Task<SSHClient, Error>?
        var closed = false
        init(listener: NWListener, port: Int) {
            self.listener = listener
            self.port = port
        }
    }

    private var open: [String: Open] = [:]
    private var starting: [String: (gen: UInt64, task: Task<Int, Error>)] = [:]
    private var generation: [String: UInt64] = [:]

    /// The address to use on the phone for a service at `remote` (like http://127.0.0.1:8931/mcp) on `host`.
    func url(for remote: String, through host: Hills.Host) async throws -> String {
        guard var parts = URLComponents(string: remote) else { throw ProviderError("看不懂这个远端地址：\(remote)") }
        let remoteScheme = parts.scheme?.lowercased() ?? "http"
        guard remoteScheme == "http" || remoteScheme == "https" else {
            throw ProviderError("隧道只支持 http 或 https 地址：\(remote)")
        }
        let remotePort = parts.port ?? (remoteScheme == "https" ? 443 : 80)
        let target = parts.host ?? "127.0.0.1"
        // Who the host is now is part of the key: an edited host never reuses a tunnel to where it used to point.
        let key = "\(host.id)|\(host.user)@\(host.address):\(host.port)|\(target):\(remotePort)"
        let local = try await localPort(key: key, host: host, targetHost: target, targetPort: remotePort)
        parts.scheme = remoteScheme
        parts.host = (target.lowercased() == "localhost") ? "localhost" : "127.0.0.1"
        parts.port = local
        guard let url = parts.string else { throw ProviderError("隧道地址拼不出来") }
        return url
    }

    /// Closes every tunnel (when the app goes away or a host is removed).
    func closeAll() async {
        for key in Set(open.keys).union(starting.keys) {
            generation[key] = generation[key, default: 0] &+ 1
        }
        for pending in starting.values {
            pending.task.cancel()
        }
        starting = [:]
        let tunnels = Array(open.values)
        open = [:]
        for tunnel in tunnels {
            tunnel.closed = true
            tunnel.connectingClient?.cancel()
            tunnel.connectingClient = nil
            tunnel.listener.cancel()
            let oldClient = tunnel.client
            tunnel.client = nil
            try? await oldClient?.close()
        }
    }

    /// Closes the tunnels through one host (it was edited or removed).
    func close(host id: String) async {
        let prefix = id + "|"
        for (key, pending) in starting where key.hasPrefix(prefix) {
            generation[key] = generation[key, default: 0] &+ 1
            pending.task.cancel()
            starting[key] = nil
        }
        var toClose: [Open] = []
        for (key, tunnel) in open where key.hasPrefix(prefix) {
            generation[key] = generation[key, default: 0] &+ 1
            tunnel.closed = true
            tunnel.connectingClient?.cancel()
            tunnel.connectingClient = nil
            tunnel.listener.cancel()
            open[key] = nil
            toClose.append(tunnel)
        }
        for tunnel in toClose {
            let oldClient = tunnel.client
            tunnel.client = nil
            try? await oldClient?.close()
        }
    }

    private func localPort(key: String, host: Hills.Host, targetHost: String, targetPort: Int) async throws -> Int {
        let currentGen = generation[key, default: 0]
        if let kept = open[key], !kept.closed, kept.listener.state == .ready { return kept.port }
        if let inFlight = starting[key], inFlight.gen == currentGen {
            return try await inFlight.task.value
        }
        if let stale = open.removeValue(forKey: key) {
            stale.closed = true
            stale.connectingClient?.cancel()
            stale.connectingClient = nil
            stale.listener.cancel()
            let oldClient = stale.client
            stale.client = nil
            Task { try? await oldClient?.close() }
        }
        let nextGen = currentGen &+ 1
        generation[key] = nextGen
        let task = Task<Int, Error> {
            do {
                let (listener, port) = try await Self.bindLoopback(preferring: targetPort)
                return try await self.finishListener(key: key, gen: nextGen, listener: listener, port: port, host: host, targetHost: targetHost, targetPort: targetPort)
            } catch {
                await self.clearStarting(key: key, gen: nextGen)
                throw error
            }
        }
        starting[key] = (nextGen, task)
        return try await task.value
    }

    private func finishListener(key: String, gen: UInt64, listener: NWListener, port: Int, host: Hills.Host, targetHost: String, targetPort: Int) throws -> Int {
        if starting[key]?.gen == gen {
            starting.removeValue(forKey: key)
        }
        guard generation[key, default: 0] == gen else {
            listener.cancel()
            throw CancellationError()
        }
        let tunnel = Open(listener: listener, port: port)
        open[key] = tunnel
        listener.newConnectionHandler = { connection in
            Task { await self.carry(connection, key: key, host: host, targetHost: targetHost, targetPort: targetPort) }
        }
        return port
    }

    private func clearStarting(key: String, gen: UInt64) {
        if starting[key]?.gen == gen {
            starting.removeValue(forKey: key)
        }
    }

    /// Binds strictly to IPv4 loopback (`127.0.0.1`) without `allowLocalEndpointReuse`.
    /// Falls back to an ephemeral port (`127.0.0.1:0`) if the preferred port is already in use.
    private static func bindLoopback(preferring port: Int) async throws -> (NWListener, Int) {
        if (1...65535).contains(port), let wanted = NWEndpoint.Port(rawValue: UInt16(port)) {
            if let preferred = try? makeLoopbackListener(port: wanted) {
                if let boundPort = try? await ready(preferred), boundPort > 0 {
                    return (preferred, boundPort)
                }
                preferred.cancel()
            }
        }
        let fallback = try makeLoopbackListener(port: .any)
        do {
            let boundPort = try await ready(fallback)
            guard boundPort > 0 else {
                fallback.cancel()
                throw ProviderError("隧道没拿到本地端口")
            }
            return (fallback, boundPort)
        } catch {
            fallback.cancel()
            throw error
        }
    }

    private static func makeLoopbackListener(port: NWEndpoint.Port) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        return try NWListener(using: parameters)
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
            let (client, wasCached) = try await sshClient(key: key, host: host, fresh: false)
            let settings = SSHChannelType.DirectTCPIP(targetHost: targetHost, targetPort: targetPort, originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
            let channel: Channel
            do {
                channel = try await client.createDirectTCPIPChannel(using: settings) { ch in
                    ch.pipeline.addHandler(Relay(connection))
                }
            } catch where wasCached {
                let (reconnected, _) = try await sshClient(key: key, host: host, fresh: true)
                channel = try await reconnected.createDirectTCPIPChannel(using: settings) { ch in
                    ch.pipeline.addHandler(Relay(connection))
                }
            }
            Self.pump(connection, into: channel)
        } catch {
            Diag.note("隧道连不上 \(host.name) 的 \(targetHost):\(targetPort)：\(error.localizedDescription)")
            connection.cancel()
        }
    }

    private func sshClient(key: String, host: Hills.Host, fresh: Bool) async throws -> (SSHClient, Bool) {
        guard let tunnel = open[key], !tunnel.closed else {
            throw ProviderError("隧道已经关闭")
        }
        if !fresh, let existing = tunnel.client, existing.isConnected {
            return (existing, true)
        }
        if !fresh, let inFlight = tunnel.connectingClient {
            return (try await inFlight.value, false)
        }
        tunnel.connectingClient?.cancel()
        if let staleClient = tunnel.client {
            tunnel.client = nil
            Task { try? await staleClient.close() }
        }
        let task = Task<SSHClient, Error> {
            do {
                let connected = try await Hills.connect(host)
                return try await self.finishSSHClient(key: key, tunnel: tunnel, client: connected)
            } catch {
                await self.clearSSHClientTask(tunnel: tunnel)
                throw error
            }
        }
        tunnel.connectingClient = task
        return (try await task.value, false)
    }

    private func finishSSHClient(key: String, tunnel: Open, client: SSHClient) async throws -> SSHClient {
        tunnel.connectingClient = nil
        guard open[key] === tunnel, !tunnel.closed else {
            try? await client.close()
            throw ProviderError("隧道已经关闭")
        }
        if let replaced = tunnel.client, replaced !== client {
            Task { try? await replaced.close() }
        }
        tunnel.client = client
        return client
    }

    private func clearSSHClientTask(tunnel: Open) {
        tunnel.connectingClient = nil
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
