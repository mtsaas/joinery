import Foundation

/// A session joined from a host's link. Connects `ClientCore`, which keeps the protocol, to a WebSocket: reconnecting
/// when it drops, with what's shown here caught up on reconnecting and nothing made here lost or made twice.
///
/// Like remote access: the model is open here only while the session is, and nothing's kept after.
@MainActor @Observable
final class SessionClient: Session {
    private(set) var peers: [String: Peer] = [:]
    private(set) var status = "Connecting…"

    @ObservationIgnored private let core: ClientCore
    @ObservationIgnored private let url: URL
    @ObservationIgnored private weak var model: OpenModel?
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    /// Counts connections, so what's heard on one already let go of is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var reconnecting: Task<Void, Never>?
    /// Heard once let in: the session's title and the host's copy, to open.
    @ObservationIgnored private var onWelcome: ((String, Replica) -> Void)?
    /// Told why, when the host turns down a change made here (which is then taken back).
    @ObservationIgnored var onRefusal: ((String) -> Void)?
    /// Told why, when the session ends: left, or the host stopped.
    @ObservationIgnored var onEnd: ((String) -> Void)?

    /// Connects to the session at `link`, calling `welcomed` with its title and the host's copy once in.
    init?(link: String, welcomed: @escaping (String, Replica) -> Void) {
        guard let (url, token) = SessionLink.address(of: link) else { return nil }
        self.url = url
        core = ClientCore(token: token, name: Self.ownName)
        onWelcome = welcomed
        connect()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.perform(self.core.tick(at: .now))
            }
        }
    }

    /// Joined, with the model opened: changes made to it from now on are shared.
    func attach(to model: OpenModel) {
        self.model = model
        model.adopt(core.shown)
        model.session = self
        model.onChange = { [weak self] ops in
            guard let self else { return }
            self.perform(self.core.changedHere(ops))
        }
    }

    func share(cursor: CGPoint?, selection: [UUID]) {
        perform(core.share(cursor: cursor, selection: selection))
    }

    func close() {
        perform(core.leave())
    }

    // MARK: Connection

    private func connect() {
        generation += 1
        let generation = generation
        task?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = SocketPeer.maximumMessage
        self.task = task
        task.resume()
        perform(core.connected(at: .now))
        receive(on: task, generation)
    }

    private func receive(on task: URLSessionWebSocketTask, _ generation: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                switch result {
                case .success(.string(let text)):
                    self.perform(self.core.received(text, at: .now))
                    if generation == self.generation { self.receive(on: task, generation) }
                case .success:
                    self.receive(on: task, generation)
                case .failure:
                    self.perform(self.core.disconnected())
                }
            }
        }
    }

    private func perform(_ effects: [ClientCore.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let message):
                task?.send(.string(message.text)) { _ in }
            case .show(let replica):
                if let model, model.replica != replica { model.adopt(replica) }
            case .welcomed(let title):
                onWelcome?(title, core.shown)
                onWelcome = nil
            case .reconnect(let delay):
                // Let go of this connection at once, so nothing more's heard on it.
                generation += 1
                task?.cancel(with: .goingAway, reason: nil)
                task = nil
                reconnecting?.cancel()
                reconnecting = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    self?.connect()
                }
            case .refused(let reason):
                onRefusal?(reason)
            case .ended(let reason):
                generation += 1
                task?.cancel(with: .normalClosure, reason: nil)
                task = nil
                ticker?.cancel()
                reconnecting?.cancel()
                onWelcome = nil
                status = reason
                model?.onChange = nil
                if model?.session === self { model?.session = nil }
                onEnd?(reason)
            }
        }
        status = switch core.state {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .ended: status
        }
        if peers != core.peers { peers = core.peers }
    }
}
