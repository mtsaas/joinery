import CryptoKit
import Foundation
import Network

@testable import Joinery

/// A relay in the test process, for the app's sessions to share through: `RelayCore`, the reference the Zig relay is
/// checked against, behind WebSockets on a free port of this Mac.
@MainActor
final class TestRelay {
    private(set) var port: UInt16?
    let core = RelayCore()
    private let listener: NWListener
    private var sockets: [RelayCore.Connection: SocketPeer] = [:]
    private var nextConnection = 1

    var address: URL { URL(string: "http://127.0.0.1:\(port ?? 0)")! }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(SocketPeer(connection, page: Data())) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in if case .ready = state { self?.port = self?.listener.port?.rawValue } }
        }
        listener.start(queue: .main)
    }

    /// A relay that's listening.
    static func started() async throws -> TestRelay {
        let relay = try TestRelay()
        for _ in 0..<300 where relay.port == nil { try await Task.sleep(for: .milliseconds(10)) }
        return relay
    }

    func stop() {
        listener.cancel()
        for socket in sockets.values { socket.close() }
    }

    private func accept(_ socket: SocketPeer) {
        let connection = nextConnection
        nextConnection += 1
        sockets[connection] = socket
        core.opened(connection, at: .now)
        socket.onMessage = { [weak self] bytes in
            guard let self else { return }
            self.perform(self.core.received(bytes, on: connection, at: .now))
        }
        socket.onClose = { [weak self] in
            guard let self, self.sockets.removeValue(forKey: connection) != nil else { return }
            self.perform(self.core.closed(connection, at: .now))
        }
        socket.start()
    }

    private func perform(_ effects: [RelayCore.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let connection, let bytes): sockets[connection]?.send(bytes)
            case .close(let connection): sockets.removeValue(forKey: connection)?.close()
            }
        }
    }
}

/// One connection to the test relay, as a server sees it: a WebSocket (RFC 6455) carrying binary messages.
@MainActor
final class SocketPeer {
    var onMessage: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?
    /// Larger messages close the connection: nothing in a session needs one this big.
    static let maximumMessage = 16 << 20

    private let connection: NWConnection
    /// What's served to a browser asking for the page instead of a socket.
    private let page: Data
    private var buffer = Data()
    /// A message arriving in pieces.
    private var fragments = Data()
    private var isUpgraded = false
    private var isClosed = false

    init(_ connection: NWConnection, page: Data) {
        self.connection = connection
        self.page = page
    }

    func start() {
        connection.start(queue: .main)
        receive()
    }

    func send(_ bytes: [UInt8]) {
        send(opcode: 2, Data(bytes))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if isUpgraded { send(opcode: 8, Data()) }
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() })
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            // On the main actor's own turn, not the network's callback, so what changes is drawn.
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                if let data { self.buffer += data }
                self.isUpgraded ? self.readFrames() : self.readRequest()
                if isComplete || error != nil { self.close() } else if !self.isClosed { self.receive() }
            }
        }
    }

    // MARK: HTTP

    private func readRequest() {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 << 10 { close() }
            return
        }
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        buffer = Data(buffer[end.upperBound...])
        let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { first, _ in first })
        let words = lines.first?.split(separator: " ") ?? []
        guard words.first == "GET" else { return respond("405 Method Not Allowed") }
        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            connection.send(content: Data("""
                HTTP/1.1 101 Switching Protocols\r
                Upgrade: websocket\r
                Connection: Upgrade\r
                Sec-WebSocket-Accept: \(accept)\r
                \r

                """.utf8), completion: .idempotent)
            isUpgraded = true
            readFrames()
        } else if words.count > 1, words[1].split(separator: "?").first == "/" {
            respond("200 OK", type: "text/html; charset=utf-8", page)
        } else {
            respond("404 Not Found")
        }
    }

    /// Answers a plain request, then closes.
    private func respond(_ status: String, type: String? = nil, _ body: Data = Data()) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + body, completion: .idempotent)
        close()
    }

    // MARK: Frames

    private func readFrames() {
        while !isClosed, let frame = nextFrame() {
            switch frame.opcode {
            case 0, 2:
                fragments += frame.payload
                guard fragments.count <= Self.maximumMessage else { return close() }
                if frame.isFinal {
                    let bytes = [UInt8](fragments)
                    fragments = Data()
                    onMessage?(bytes)
                }
            case 8: close()
            case 9: send(opcode: 10, frame.payload)
            case 10: break
            // Text, or anything else: not part of the protocol.
            default: close()
            }
        }
    }

    private func nextFrame() -> (isFinal: Bool, opcode: UInt8, payload: Data)? {
        let head = [UInt8](buffer.prefix(14))
        guard head.count >= 2 else { return nil }
        var length = Int(head[1] & 0x7F), offset = 2
        if length == 126 {
            guard head.count >= 4 else { return nil }
            length = Int(head[2]) << 8 | Int(head[3])
            offset = 4
        } else if length == 127 {
            guard head.count >= 10 else { return nil }
            guard head[2..<6].allSatisfy({ $0 == 0 }) else { close(); return nil }
            length = head[6..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        guard length <= Self.maximumMessage else { close(); return nil }
        let isMasked = head[1] & 0x80 != 0
        let mask = isMasked && head.count >= offset + 4 ? Array(head[offset..<offset + 4]) : nil
        if isMasked { offset += 4 }
        guard buffer.count >= offset + length else { return nil }
        var payload = [UInt8](buffer.dropFirst(offset).prefix(length))
        if let mask { for index in payload.indices { payload[index] ^= mask[index % 4] } }
        buffer = Data(buffer.dropFirst(offset + length))
        return (head[0] & 0x80 != 0, head[0] & 0x0F, Data(payload))
    }

    private func send(opcode: UInt8, _ payload: Data) {
        guard isUpgraded else { return }
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame += [126, UInt8(count >> 8), UInt8(count & 0xFF)]
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((count >> shift) & 0xFF)) }
        }
        connection.send(content: frame + payload, completion: .idempotent)
    }
}
