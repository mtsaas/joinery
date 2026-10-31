import Foundation
import Network

/// A connection to a relay: a `RelaySocket`, which carries everything, and beside it, once the relay sends a ticket and
/// a probe comes back, a UDP socket that carries presence (see `docs/relay.md`, "Presence over UDP"). `UdpLink` decides
/// which way presence goes; this does what it says and wakes it when it asks. Used as a `RelaySocket` is: frames in and
/// out, whichever way they came.
@MainActor
final class RelayConnection {
    var onMessage: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    /// Presence over UDP, unless turned off with `defaults write <bundle ID> relayUDP -bool NO`.
    static var udpEnabled: Bool { UserDefaults.standard.object(forKey: "relayUDP") as? Bool ?? true }
    /// How long it waits for what; tests shorten it.
    static var timing = UdpLink.Timing()

    /// Whether presence is going by UDP now.
    var presenceOverUDP: Bool { link.isUp }

    private let socket: RelaySocket
    private let host: NWEndpoint.Host
    private var link: UdpLink
    private var udp: NWConnection?
    /// Counts UDP sockets, so what's heard on one let go of is ignored, as `RelaySocket` does for its connections.
    private var generation = 0
    private var wake: Task<Void, Never>?

    init(_ url: URL) {
        socket = RelaySocket(url)
        host = NWEndpoint.Host(url.host ?? "localhost")
        link = UdpLink(enabled: Self.udpEnabled, timing: Self.timing)
        socket.onMessage = { [weak self] bytes in self?.heard(bytes) }
        socket.onClose = { [weak self] in
            guard let self else { return }
            perform(link.disconnected())
            onClose?()
        }
    }

    /// Connects afresh: any ticket the last connection had goes with it.
    func connect() {
        perform(link.disconnected())
        socket.connect()
    }

    func send(_ bytes: [UInt8]) {
        if bytes.count > 1, bytes[1] == Wire.Kind.presence.rawValue {
            perform([link.presence(bytes, at: .now)])
        } else {
            socket.send(bytes)
        }
    }

    func close() {
        socket.close()
        perform(link.disconnected())
    }

    // MARK: What's heard

    private func heard(_ bytes: [UInt8]) {
        // The ticket is the transport's; everything else is the session's.
        if bytes.count >= Wire.Header.size, bytes[1] == Wire.Kind.udpTicket.rawValue {
            perform(link.ticket(Array(bytes[Wire.Header.size...]), at: .now))
        } else {
            onMessage?(bytes)
        }
    }

    private func heardDatagram(_ bytes: [UInt8]) {
        let frame = link.datagram(bytes, at: .now)
        schedule()
        if let frame { onMessage?(frame) }
    }

    // MARK: Doing what the link says

    private func perform(_ effects: [UdpLink.Effect]) {
        for effect in effects {
            switch effect {
            case .open(let host, let port): open(host.map { NWEndpoint.Host($0) } ?? self.host, port)
            case .close: closeUDP()
            case .datagram(let bytes): udp?.send(content: Data(bytes), completion: .idempotent)
            case .webSocket(let bytes): socket.send(bytes)
            }
        }
        schedule()
    }

    /// A tick at the link's deadline, in place of any due.
    private func schedule() {
        wake?.cancel()
        wake = nil
        guard let deadline = link.deadline else { return }
        wake = Task { [weak self] in
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            perform(link.tick(.now))
        }
    }

    private func open(_ host: NWEndpoint.Host, _ port: UInt16) {
        closeUDP()
        guard let port = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: host, port: port, using: .udp)
        generation += 1
        let generation = generation
        connection.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                self.perform(self.link.socketFailed(at: .now))
            }
        }
        udp = connection
        connection.start(queue: .main)
        receive(on: connection, generation)
    }

    private func receive(on connection: NWConnection, _ generation: Int) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                if let data { self.heardDatagram(Array(data)) }
                if error == nil {
                    self.receive(on: connection, generation)
                } else {
                    self.perform(self.link.socketFailed(at: .now))
                }
            }
        }
    }

    private func closeUDP() {
        generation += 1
        udp?.cancel()
        udp = nil
    }
}
