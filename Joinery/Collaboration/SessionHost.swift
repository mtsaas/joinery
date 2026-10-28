import Foundation
import Network

/// Hosts a session on the open model: others join at `port`, here or through a tunnel that exposes it, with the
/// token. Connects `HostCore`, which keeps the protocol, to sockets: the page and WebSockets on one port, on this Mac
/// only.
@MainActor @Observable
final class SessionHost: Session {
    static let defaultPort: UInt16 = 8724

    var token: String { core.token }
    var me: Peer { core.me }
    private(set) var peers: [String: Peer] = [:]
    private(set) var status = "Starting…"
    /// The port it's listening on, once it is.
    private(set) var port: UInt16?
    var isHost: Bool { true }

    @ObservationIgnored private let core: HostCore
    @ObservationIgnored private weak var model: OpenModel?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var sockets: [HostCore.Connection: SocketPeer] = [:]
    @ObservationIgnored private var nextConnection = 1
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Starts listening on `port` on this Mac only (0 for any free one), for the open model.
    init(model: OpenModel, port: UInt16 = defaultPort, token: String = SessionHost.newToken()) throws {
        self.model = model
        core = HostCore(document: model, token: token, name: Self.ownName)
        let parameters = NWParameters.tcp
        // Only this Mac: the tunnel that exposes it connects from here too.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let page = Bundle.main.url(forResource: "WebClient", withExtension: "html").flatMap { try? Data(contentsOf: $0) } ?? Data()
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(SocketPeer(connection, page: page)) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener?.port?.rawValue
                    self.status = "Sharing on port \(self.port ?? 0)"
                case .failed(let error), .waiting(let error):
                    self.status = error == .posix(.EADDRINUSE) ? "Port \(port) is in use by another app." : error.localizedDescription
                    self.close()
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
        model.onChange = { [weak self] ops in
            guard let self else { return }
            self.perform(self.core.changedHere(ops))
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.perform(self.core.tick(at: .now))
            }
        }
    }

    /// 128 random bits, as letters and digits.
    nonisolated static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(generator.next() as UInt32, radix: 36) }.joined()
    }

    /// The link that opens the session: in a browser, the web client; pasted into Join, the app. `address` is where
    /// others reach the port, such as a tunnel's `https://…` address.
    func link(at address: String) -> String {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") { address = "http://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        return "\(address)/#token=\(token)"
    }

    func share(cursor: CGPoint?, selection: [UUID]) {
        perform(core.share(Peer(id: me.id, name: me.name, color: me.color, cursor: cursor.map { [$0.x, $0.y] },
                                selection: selection.map(\.uuidString))))
    }

    func close() {
        guard listener != nil else { return }
        perform(core.stop("The host stopped sharing. This copy is yours to keep."))
        listener?.cancel()
        listener = nil
        ticker?.cancel()
        sockets = [:]
        peers = [:]
        if model?.session === self { model?.session = nil }
        model?.onChange = nil
        if status.hasPrefix("Sharing") || status.hasPrefix("Starting") { status = "Stopped sharing" }
    }

    private func accept(_ socket: SocketPeer) {
        guard listener != nil else { return socket.close() }
        let connection = nextConnection
        nextConnection += 1
        sockets[connection] = socket
        core.opened(connection, at: .now)
        socket.onText = { [weak self] text in
            guard let self else { return }
            self.perform(self.core.received(text, on: connection, at: .now))
        }
        socket.onClose = { [weak self] in
            guard let self, self.sockets.removeValue(forKey: connection) != nil else { return }
            self.perform(self.core.closed(connection))
        }
        socket.start()
    }

    private func perform(_ effects: [HostCore.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let connection, let message): sockets[connection]?.send(message.text)
            case .close(let connection): sockets[connection]?.close()
            }
        }
        if peers != core.peers { peers = core.peers }
    }
}

extension OpenModel: SharedDocument {
    var title: String { name }
}
