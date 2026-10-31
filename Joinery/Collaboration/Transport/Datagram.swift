import CommonCrypto
import CryptoKit
import Foundation

/// Presence over UDP (see `docs/relay.md`, "Presence over UDP"): the ticket a relay sends a connection, and datagrams
/// sealed with it, AES-128-GCM under its key. Byte for byte what `relay/src/server/udp.zig` writes and reads.
enum Datagram {
    /// Before the sealed header: the ID, the masked counter and the tag.
    static let prefix = 32
    static let maxSize = 1400
    static let ticketSize = 42

    enum Direction: UInt8 { case toRelay = 0, toClient = 1 }

    /// A connection's ID and keys, and where the relay takes UDP, from the body of its `udpTicket` frame.
    struct Ticket: Equatable {
        var id: UInt64
        var key: [UInt8]
        var maskKey: [UInt8]
        var port: UInt16
        /// Where to send to, if not the WebSocket's host.
        var host: String?

        init?(_ body: [UInt8]) {
            guard body.count >= Datagram.ticketSize, body.count <= Datagram.ticketSize + 253 else { return nil }
            let host = String(decoding: body[Datagram.ticketSize...], as: UTF8.self)
            self.host = host.isEmpty ? nil : host
            id = body.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            key = Array(body[8..<24])
            maskKey = Array(body[24..<40])
            port = UInt16(body[40]) | UInt16(body[41]) << 8
        }
    }

    /// A probe: a header alone, of kind `udpTicket`. Over UDP, the relay answers one with one; over the WebSocket, it
    /// means "send me nothing more by UDP".
    static let probe = Wire.Header(kind: .udpTicket, length: 0).bytes

    /// One connection's datagrams, both ways: its counter, and the window of counters it has taken.
    struct Session {
        let id: UInt64
        private let key: SymmetricKey
        private let mask: BlockCipher
        private(set) var sent: UInt64 = 0
        private var newest: UInt64 = 0
        private var seen: UInt64 = 0

        init(_ ticket: Ticket) {
            id = ticket.id
            key = SymmetricKey(data: ticket.key)
            mask = BlockCipher(key: ticket.maskKey)
        }

        /// `frame`, a header and its body, as a datagram.
        mutating func seal(_ direction: Direction, _ frame: [UInt8]) -> [UInt8] {
            precondition(frame.count >= Wire.Header.size && Datagram.prefix + frame.count <= Datagram.maxSize)
            sent += 1
            let body = frame[Wire.Header.size...]
            // swiftlint:disable:next force_try
            let box = try! AES.GCM.seal(frame[..<Wire.Header.size], using: key, nonce: Self.nonce(direction, sent), authenticating: body)
            var out = [UInt8](repeating: 0, count: Datagram.prefix)
            out.reserveCapacity(Datagram.prefix + frame.count)
            out.replaceSubrange(0..<8, with: withUnsafeBytes(of: id.littleEndian, Array.init))
            out.replaceSubrange(16..<32, with: box.tag)
            out.append(contentsOf: box.ciphertext)
            out.append(contentsOf: body)
            let counter = sent ^ mask.firstWord(of: out[Datagram.prefix..<Datagram.prefix + 16])
            out.replaceSubrange(8..<16, with: withUnsafeBytes(of: counter.littleEndian, Array.init))
            return out
        }

        /// The frame in `datagram`, if it's this session's, opens, and hasn't been taken already. Nothing about the
        /// session changes for one that doesn't.
        mutating func open(_ direction: Direction, _ datagram: [UInt8]) -> [UInt8]? {
            guard datagram.count >= Datagram.prefix + Wire.Header.size, datagram.count <= Datagram.maxSize,
                  datagram.withUnsafeBytes({ UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }) == id
            else { return nil }
            let masked = datagram.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
            let counter = masked ^ mask.firstWord(of: datagram[Datagram.prefix..<Datagram.prefix + 16])
            // Not one before the window: more than 64 behind the newest taken.
            guard counter != 0, newest < 64 || counter > newest - 64 else { return nil }
            if counter <= newest, seen >> (newest - counter) & 1 != 0 { return nil }
            let sealedEnd = Datagram.prefix + Wire.Header.size
            let body = datagram[sealedEnd...]
            guard let box = try? AES.GCM.SealedBox(nonce: Self.nonce(direction, counter), ciphertext: datagram[Datagram.prefix..<sealedEnd], tag: datagram[16..<32]),
                  let header = try? AES.GCM.open(box, using: key, authenticating: body)
            else { return nil }
            if counter > newest {
                let ahead = counter - newest
                seen = ahead >= 64 ? 1 : seen << ahead | 1
                newest = counter
            } else {
                seen |= 1 << (newest - counter)
            }
            return Array(header) + body
        }

        private static func nonce(_ direction: Direction, _ counter: UInt64) -> AES.GCM.Nonce {
            var bytes = [direction.rawValue, 0, 0, 0]
            bytes.append(littleEndian: counter)
            // swiftlint:disable:next force_try
            return try! AES.GCM.Nonce(data: bytes)
        }
    }

    /// AES-128 on single blocks, for masking counters. CryptoKit has no raw block cipher, so CommonCrypto's, in ECB
    /// mode, which on one block is exactly that.
    final class BlockCipher: @unchecked Sendable {
        private var cryptor: CCCryptorRef?

        init(key: [UInt8]) {
            precondition(key.count == kCCKeySizeAES128)
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, key.count, nil, &cryptor)
        }

        deinit { CCCryptorRelease(cryptor) }

        /// The first 8 bytes of `block` encrypted, little-endian.
        func firstWord(of block: ArraySlice<UInt8>) -> UInt64 {
            precondition(block.count == 16)
            var out = [UInt8](repeating: 0, count: 16)
            var moved = 0
            block.withUnsafeBytes { input in
                _ = CCCryptorUpdate(cryptor, input.baseAddress, 16, &out, 16, &moved)
            }
            return out.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        }
    }
}
