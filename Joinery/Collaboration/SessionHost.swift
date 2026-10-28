import Foundation
import Network

/// Hosts a session on the open model: others join at `port`, here or through a tunnel that exposes it, with the
/// token. The model here is the one true copy. Every change, made here or sent in, is numbered and sent to everyone
/// in order, so all copies end up the same.
@MainActor @Observable
final class SessionHost: Session {
    static let defaultPort: UInt16 = 8724

    let token: String
    let me: Peer
    private(set) var peers: [String: Peer] = [:]
    private(set) var status = "Starting…"
    /// The port it's listening on, once it is.
    private(set) var port: UInt16?
    var isHost: Bool { true }

    @ObservationIgnored private weak var model: OpenModel?
    @ObservationIgnored private var listener: NWListener?
    /// Connections, and who each is once they've said hello.
    @ObservationIgnored private var sockets: [ObjectIdentifier: SocketPeer] = [:]
    @ObservationIgnored private var joined: [ObjectIdentifier: String] = [:]
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var colors = 0

    /// Starts listening on `port` on this Mac only (0 for any free one), for the open model.
    init(model: OpenModel, port: UInt16 = defaultPort, token: String = SessionHost.newToken()) throws {
        self.token = token
        self.model = model
        me = Peer(id: "host", name: Self.ownName, color: "blue")
        let parameters = NWParameters.tcp
        // Only this Mac: the tunnel that exposes it connects from here too.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let page = (Bundle.main.url(forResource: "WebClient", withExtension: "html")).flatMap { try? Data(contentsOf: $0) } ?? Data()
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(SocketPeer(connection, page: page)) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
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
        model.onChange = { [weak self] ops in self?.publish(ops, author: "host") }
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
        var message = Message("presence")
        message.peer = Peer(id: me.id, name: me.name, color: me.color, cursor: cursor.map { [$0.x, $0.y] },
                            selection: selection.map(\.uuidString))
        broadcast(message)
    }

    func close() {
        listener?.cancel()
        listener = nil
        for socket in sockets.values { socket.close() }
        sockets = [:]
        peers = [:]
        if model?.session === self { model?.session = nil }
        model?.onChange = nil
        if status.hasPrefix("Sharing") || status.hasPrefix("Starting") { status = "Stopped sharing" }
    }

    // MARK: Messages

    private func accept(_ socket: SocketPeer) {
        let key = ObjectIdentifier(socket)
        sockets[key] = socket
        socket.onText = { [weak self, weak socket] text in
            guard let self, let socket else { return }
            self.receive(text, from: socket)
        }
        socket.onClose = { [weak self] in
            guard let self else { return }
            self.sockets[key] = nil
            if let id = self.joined.removeValue(forKey: key) {
                self.peers[id] = nil
                var left = Message("left")
                left.peer = Peer(id: id, name: "", color: "")
                self.broadcast(left)
            }
        }
        socket.start()
    }

    private func receive(_ text: String, from socket: SocketPeer) {
        let key = ObjectIdentifier(socket)
        guard let message = Message(text: text) else { return reject(socket, "That isn't a message.") }
        guard let id = joined[key] else {
            // Only hello, with the token, before anything else.
            guard message.type == "hello", message.token == token, message.protocol == Message.version else {
                var refusal = Message("reject")
                refusal.reason = message.protocol != Message.version && message.type == "hello"
                    ? "This copy of Joinery speaks protocol \(Message.version)." : "That link isn't valid, or the session has ended."
                socket.send(refusal.text)
                return socket.close()
            }
            welcome(socket, name: message.name)
            return
        }
        switch message.type {
        case "ops":
            guard let model, let ops = message.ops else { return }
            do {
                let tidying = try model.receive(ops)
                publish(ops, author: id, cseq: message.cseq)
                if !tidying.isEmpty { publish(tidying, author: "host") }
            } catch {
                var rejection = Message("reject")
                rejection.cseq = message.cseq
                rejection.reason = error.localizedDescription
                socket.send(rejection.text)
            }
        case "presence":
            guard var peer = peers[id] else { return }
            peer.cursor = message.cursor
            peer.selection = message.selection
            peers[id] = peer
            var presence = Message("presence")
            presence.peer = peer
            broadcast(presence, except: id)
        default:
            break
        }
    }

    private func welcome(_ socket: SocketPeer, name: String?) {
        guard let model else { return socket.close() }
        let id = UUID().uuidString
        let colors = ["purple", "pink", "orange", "green", "teal", "indigo", "red", "mint", "cyan", "brown", "yellow"]
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
        let peer = Peer(id: id, name: name.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? "Guest", color: colors[self.colors % colors.count])
        self.colors += 1
        var welcome = Message("welcome")
        welcome.protocol = Message.version
        welcome.you = id
        welcome.seq = seq
        welcome.title = model.name
        welcome.entities = model.replica.entities.keys.sorted().compactMap { model.replica.entities[$0] }
        welcome.peers = [me] + peers.values
        socket.send(welcome.text)
        joined[ObjectIdentifier(socket)] = id
        peers[id] = peer
        var joinedMessage = Message("joined")
        joinedMessage.peer = peer
        broadcast(joinedMessage, except: id)
    }

    /// Numbers a change and sends it to everyone, its author included, who learns from it that theirs went through.
    private func publish(_ ops: [Replica.Op], author: String, cseq: Int? = nil) {
        guard !ops.isEmpty else { return }
        seq += 1
        var message = Message("ops")
        message.seq = seq
        message.author = author
        message.cseq = cseq
        message.ops = ops
        broadcast(message)
    }

    private func broadcast(_ message: Message, except excluded: String? = nil) {
        let text = message.text
        for (key, socket) in sockets {
            guard let id = joined[key], id != excluded else { continue }
            socket.send(text)
        }
    }

    private func reject(_ socket: SocketPeer, _ reason: String) {
        var rejection = Message("reject")
        rejection.reason = reason
        socket.send(rejection.text)
    }
}
