import Foundation

/// A client's side of presence over UDP, for one WebSocket connection at a time (see `docs/relay.md`, "Presence over
/// UDP"): when to probe, which way presence goes, when to give up on UDP, and when to try it again. No network and no
/// clock of its own: events and the time go in, what to do comes out, and `deadline` says when it next wants a `tick`.
///
/// The WebSocket always works, so every state has somewhere for presence to go:
///
///     off ──ticket──▶ probing ──an answer──▶ up
///                       │                    │ nothing heard for `silence`, or the socket fails
///                       │ no answer          ▼
///                       └────────────────▶ down ──after `retry`, doubling──▶ probing
///
/// Any state goes to off when the WebSocket drops: a ticket is good for one connection.
struct UdpLink {
    struct Timing: Equatable {
        /// When probes go, from the start of probing. None answered by `probeTimeout`, and it's down.
        var probes: [TimeInterval] = [0, 0.25, 0.5, 1, 2, 4]
        var probeTimeout: TimeInterval = 8
        /// Up, it probes once it's heard nothing for `idle`, and gives up once it's heard nothing for `silence`.
        var idle: TimeInterval = 5
        var silence: TimeInterval = 15
        /// Down, it tries again after `retry`, doubling each time up to `maxRetry`, and back to `retry` once up.
        var retry: TimeInterval = 30
        var maxRetry: TimeInterval = 300
    }

    enum State: Equatable {
        /// No ticket on this connection, or UDP turned off here: presence goes by WebSocket.
        case off
        /// `sent` of the probes have gone.
        case probing(since: Date, sent: Int)
        /// Presence goes by UDP. `heard` is the last genuine datagram, `probed` the last probe.
        case up(heard: Date, probed: Date)
        /// Presence goes by WebSocket until it tries again.
        case down(until: Date)
    }

    enum Effect: Equatable {
        /// A UDP socket to `host` (nil: the WebSocket's), on this port, in place of any open.
        case open(host: String?, port: UInt16)
        case close
        case datagram([UInt8])
        case webSocket([UInt8])
    }

    let enabled: Bool
    let timing: Timing
    private(set) var state = State.off
    private var session: Datagram.Session?
    private var host: String?
    private var port: UInt16 = 0
    private var socketOpen = false
    private var retry: TimeInterval

    init(enabled: Bool = true, timing: Timing = Timing()) {
        self.enabled = enabled
        self.timing = timing
        retry = timing.retry
    }

    var isUp: Bool {
        if case .up = state { true } else { false }
    }

    /// When it next wants a `tick`, if it does.
    var deadline: Date? {
        switch state {
        case .off: nil
        case .probing(let since, let sent): since + (sent < timing.probes.count ? timing.probes[sent] : timing.probeTimeout)
        case .up(let heard, let probed): min(heard + timing.silence, max(heard, probed) + timing.idle)
        case .down(let until): until
        }
    }

    // MARK: Events

    /// A `udpTicket` frame's body, from the relay over the WebSocket.
    mutating func ticket(_ body: [UInt8], at now: Date) -> [Effect] {
        guard enabled, let ticket = Datagram.Ticket(body) else { return [] }
        session = Datagram.Session(ticket)
        host = ticket.host
        port = ticket.port
        retry = timing.retry
        state = .probing(since: now, sent: 0)
        socketOpen = true
        return [.open(host: host, port: port)] + tick(now)
    }

    /// Where `frame`, a presence frame, goes now.
    mutating func presence(_ frame: [UInt8], at now: Date) -> Effect {
        guard isUp, var session, Datagram.prefix + frame.count <= Datagram.maxSize else { return .webSocket(frame) }
        defer { self.session = session }
        return .datagram(session.seal(.toRelay, frame))
    }

    /// A datagram from the relay: the presence frame in it, if there is one, and what to do.
    mutating func datagram(_ bytes: [UInt8], at now: Date) -> [UInt8]? {
        guard var session, let frame = session.open(.toClient, bytes) else { return nil }
        self.session = session
        switch state {
        case .probing:
            state = .up(heard: now, probed: now)
            retry = timing.retry
        case .up(_, let probed):
            state = .up(heard: now, probed: probed)
        case .off, .down:
            // A late answer: down, the relay's been told to stop, and the next probe will find out afresh.
            break
        }
        return frame[1] == Wire.Kind.presence.rawValue ? frame : nil
    }

    mutating func tick(_ now: Date) -> [Effect] {
        switch state {
        case .off:
            return []
        case .probing(let since, var sent):
            var effects: [Effect] = []
            // One probe for however many are due: a late tick doesn't send a burst.
            if sent < timing.probes.count, now >= since + timing.probes[sent] {
                effects.append(probe())
                while sent < timing.probes.count, now >= since + timing.probes[sent] { sent += 1 }
            }
            state = .probing(since: since, sent: sent)
            if sent == timing.probes.count, now >= since + timing.probeTimeout { return effects + goDown(now) }
            return effects
        case .up(let heard, let probed):
            if now >= heard + timing.silence { return goDown(now) }
            guard now >= max(heard, probed) + timing.idle else { return [] }
            state = .up(heard: heard, probed: now)
            return [probe()]
        case .down(let until):
            guard now >= until else { return [] }
            state = .probing(since: now, sent: 0)
            var effects: [Effect] = []
            if !socketOpen {
                socketOpen = true
                effects.append(.open(host: host, port: port))
            }
            return effects + tick(now)
        }
    }

    /// The UDP socket failed: down, to try again later on a new one.
    mutating func socketFailed(at now: Date) -> [Effect] {
        socketOpen = false
        switch state {
        case .probing, .up: return goDown(now)
        case .off, .down: return []
        }
    }

    /// The WebSocket dropped, or was let go of: its ticket goes with it.
    mutating func disconnected() -> [Effect] {
        let wasOpen = socketOpen
        state = .off
        session = nil
        socketOpen = false
        return wasOpen ? [.close] : []
    }

    // MARK: Helpers

    private mutating func probe() -> Effect {
        // There's always a session when probing or up.
        .datagram(session!.seal(.toRelay, Datagram.probe))
    }

    /// Down: presence by WebSocket, and the relay told so, as it may still think UDP works (it heard a probe, say).
    private mutating func goDown(_ now: Date) -> [Effect] {
        state = .down(until: now + retry)
        retry = min(retry * 2, timing.maxRetry)
        return [.webSocket(Datagram.probe)]
    }
}
