import Foundation

/// A WebSocket to a relay, carrying binary frames. Each `connect` lets go of the last connection first, and nothing
/// more is heard from one let go of.
@MainActor
final class RelaySocket {
    var onMessage: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    private let url: URL
    private var task: URLSessionWebSocketTask?
    /// Counts connections, so what's heard on one already let go of is ignored.
    private var generation = 0

    init(_ url: URL) {
        self.url = url
    }

    /// Connects afresh. What's sent from now waits for the connection to open.
    func connect() {
        close()
        let task = URLSession.shared.webSocketTask(with: url)
        // The largest frame a relay takes, a snapshot, and its WebSocket header.
        task.maximumMessageSize = 2 << 20
        self.task = task
        task.resume()
        receive(on: task, generation)
    }

    func send(_ bytes: [UInt8]) {
        task?.send(.data(Data(bytes))) { _ in }
    }

    func close() {
        generation += 1
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func receive(on task: URLSessionWebSocketTask, _ generation: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                switch result {
                case .success(.data(let data)):
                    self.onMessage?(Array(data))
                    if generation == self.generation { self.receive(on: task, generation) }
                case .success:
                    self.receive(on: task, generation)
                case .failure:
                    self.close()
                    self.onClose?()
                }
            }
        }
    }
}

/// Runs `body` every `interval` while whoever holds the task does, as the cores' ticks want.
func ticking(every interval: Duration, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            body()
        }
    }
}
