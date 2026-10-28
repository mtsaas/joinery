import CryptoKit
import Foundation
import Testing
@testable import Joinery

/// The binary form of session messages.
@MainActor
struct WireTests {
    /// Each example model as the ops that would send it whole, plus a set and a delete of its first entity.
    private func exampleOps() throws -> [(name: String, ops: [Replica.Op])] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "joinery", subdirectory: nil) ?? []
        #expect(urls.count >= 5)
        return try urls.map { url in
            let replica = Replica(try DataModel(contentsOf: url))
            var ops = replica.entities.keys.sorted().map { Replica.Op.put(replica.entities[$0]!) }
            let first = replica.entities.keys.sorted()[0]
            ops += [.set(id: first, field: "name", value: .string("renamed")), .set(id: first, field: "notes", value: .null), .delete(id: first)]
            return (url.deletingPathExtension().lastPathComponent, ops)
        }
    }

    /// Values that don't come up in the examples but can in a session.
    private let unusual: [Replica.Op] = [
        .put([
            "id": .string("not-a-uuid"),
            "kind": .string("table"),
            "fromTheFuture": .object(["nested": .array([.number(-0.0), .number(1e300), .number(-1.5), .null, .bool(true), .bool(false)]),
                                      "é 🗄️": .string("")]),
            "lowercase": .string("0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9"),
            "upper": .string("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"),
            "samples": .array([.object(["id": .string("1"), "note": .string("line\nbreak \"quoted\"")])]),
        ]),
        .set(id: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", field: "a field with no code", value: .array([])),
        .set(id: "x", field: "position", value: .array([.number(0.1), .number(-2_000_000.25)])),
        .delete(id: ""),
    ]

    @Test func opsReadBackAsTheyWereWritten() throws {
        for (name, ops) in try exampleOps() + [("unusual", unusual)] {
            let bytes = Wire.encode(ops)
            #expect(try Wire.decode(bytes) == ops, "\(name)")
            // The same ops give the same bytes, however their dictionaries happen to be ordered.
            #expect(Wire.encode(try Wire.decode(bytes)) == bytes, "\(name)")
        }
    }

    /// Also attaches the sizes to the test's result, as `wire-sizes.txt`.
    @Test func opsAreSmallerThanJSON() throws {
        var report = ""
        for (name, ops) in try exampleOps() {
            let json = try JSONEncoder().encode(ops).count, binary = Wire.encode(ops).count
            report += "\(name): \(json) bytes as JSON, \(binary) as binary (\(binary * 100 / json)%)\n"
            #expect(binary * 2 < json, "\(name)")
        }
        let rename: [Replica.Op] = [.set(id: UUID().uuidString, field: "name", value: .string("orders"))]
        report += "a rename: \(try JSONEncoder().encode(rename).count) bytes as JSON, \(Wire.encode(rename).count) as binary\n"
        Attachment.record(report, named: "wire-sizes.txt")
    }

    @Test func headersReadBackAndCheckTheirVersion() throws {
        let header = Wire.Header(kind: .ops, flags: 0xBEEF, length: 1234, seq: 0x0102_0304_0506_0708, peer: 77)
        let bytes = header.bytes
        #expect(bytes.count == Wire.Header.size)
        #expect(try Wire.Header(bytes) == header)
        // Little-endian, at the offsets docs/relay.md gives.
        #expect(Array(bytes[8..<16]) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(throws: Wire.Malformed("an unknown version")) { try Wire.Header([2] + bytes.dropFirst()) }
        #expect(throws: Wire.Malformed("an unknown kind of message")) { try Wire.Header([1, 99] + bytes.dropFirst(2)) }
        #expect(throws: Wire.Malformed("too few bytes")) { try Wire.Header(bytes.prefix(23)) }
    }

    @Test func badBytesThrowInsteadOfCrashing() throws {
        let bytes = Wire.encode(try exampleOps()[0].ops + unusual)
        var generator = SplitMix(seed: 7)
        var thrown = 0
        for trial in 0..<3000 {
            var bad = bytes
            if trial % 3 == 0 {
                bad = Array(bad.prefix(Int(generator.next() % UInt64(bad.count))))
            } else {
                for _ in 0..<(1 + trial % 4) { bad[Int(generator.next() % UInt64(bad.count))] = UInt8(truncatingIfNeeded: generator.next()) }
            }
            do { _ = try Wire.decode(bad) } catch { thrown += 1 }
        }
        // Most damage is noticed; the rest decodes to other ops, which is all a relay or a host can be sure of anyway.
        #expect(thrown > 1500)
        // Nesting can't be used to run the stack out.
        #expect(throws: Wire.Malformed("values nested too deeply")) {
            // One put with one field, "id", whose value is an array in an array in an array…
            try Wire.decode([1, 1, 1, 1] + Array(repeating: [6, 1], count: 10_000).flatMap { $0 })
        }
    }

    // MARK: Sealing

    @Test func sealedFramesOpenOnlyAsSealed() throws {
        let key = SymmetricKey(size: .bits256)
        let plain = Wire.encode(unusual)
        let frame = Wire.Frame(.change, seq: 7, sealing: plain, with: key)
        #expect(frame.bytes.count == Wire.Header.size + plain.count + Wire.Frame.sealing)
        // The relay writing the sender in changes nothing.
        #expect(try Wire.Frame(Wire.stamp(frame.bytes, peer: 3)).opened(with: key) == plain)
        // Anything else changed doesn't open: the seq, the kind, the body, or the key.
        var tampered = [frame.bytes, frame.bytes, frame.bytes]
        tampered[0][8] ^= 1
        tampered[1][1] = Wire.Kind.ops.rawValue
        tampered[2][tampered[2].count - 1] ^= 1
        for bytes in tampered {
            #expect(throws: Wire.Malformed.self) { try Wire.Frame(bytes).opened(with: key) }
        }
        #expect(throws: Wire.Malformed.self) { try frame.opened(with: SymmetricKey(size: .bits256)) }
    }

    /// A guest whose link has the wrong key is told so, rather than trying again forever.
    @Test func aGuestWithTheWrongKeyIsToldToCheckTheLink() throws {
        let host = RelayHostCore(Replica(), title: "t", name: "Host")
        let snapshot = host.connected(at: .now).compactMap { effect -> [UInt8]? in if case .send(let b) = effect { b } else { nil } }[1]
        let guest = RelayGuestCore(room: "r", secret: "s", key: SymmetricKey(size: .bits256), name: "Guest")
        _ = guest.connected(at: .now)
        let welcome = Relay.Welcome(peer: 2, room: "r", limits: Relay.Limits(), latest: 0, version: Relay.roomVersion, title: [], peers: [:])
        _ = guest.received(welcome.frame.bytes, at: .now)
        guard case .ended(let reason)? = guest.received(snapshot, at: .now).first else { Issue.record("not ended"); return }
        #expect(reason == "Couldn't read this session: check the link.")
    }
}

/// A small seeded generator, so a failure here can be run again.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
