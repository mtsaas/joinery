import CryptoKit
import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Joinery

/// The binary form of session messages, in Swift and in the web client, which have to agree byte for byte.
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

    // MARK: The web client

    /// The web client's `wire` script, in JavaScriptCore, which lacks a browser's TextEncoder and TextDecoder.
    private func wireScript() throws -> String {
        let url = try #require(Bundle.main.url(forResource: "WebClient", withExtension: "html"))
        let page = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(page.range(of: "<script id=\"wire\">")).upperBound
        return String(page[start..<(try #require(page.range(of: "</script>", range: start..<page.endIndex)).lowerBound)])
    }

    private func webWire() throws -> JSContext {
        let script = try wireScript()
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript("""
            if (typeof TextEncoder === "undefined") globalThis.TextEncoder = class {
              encode(s) { return Uint8Array.from(unescape(encodeURIComponent(s)), c => c.charCodeAt(0)); } };
            if (typeof TextDecoder === "undefined") globalThis.TextDecoder = class {
              decode(b) { return decodeURIComponent(escape(Array.from(b, c => String.fromCharCode(c)).join(""))); } };
            """)
        // Its consts belong to the script; hand Wire out.
        context.evaluateScript(script + "\nglobalThis.Wire = Wire;")
        #expect(failure == nil, "\(failure ?? "")")
        return context
    }

    private func call(_ context: JSContext, _ code: String, _ arguments: [Any]) throws -> JSValue {
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        let result = try #require(context.evaluateScript(code)?.call(withArguments: arguments))
        if let failure { throw Wire.Malformed("JavaScript: \(failure)") }
        return result
    }

    private func bytes(_ value: JSValue) -> [UInt8] {
        (value.toArray() ?? []).map { ($0 as! NSNumber).uint8Value }
    }

    @Test func theWebClientReadsAndWritesTheSameBytes() throws {
        let context = try webWire()
        for (name, ops) in try exampleOps() + [("unusual", unusual)] {
            let swift = Wire.encode(ops)
            let json = String(decoding: try JSONEncoder().encode(ops), as: UTF8.self)
            // Swift's bytes, read by the web client, are the same ops.
            let read = try call(context, "(b => JSON.stringify(Wire.decodeOps(Uint8Array.from(b))))", [swift.map(Int.init)])
            #expect(try JSONDecoder().decode([Replica.Op].self, from: Data(read.toString().utf8)) == ops, "\(name)")
            // The same ops, written by the web client, are the same bytes.
            let written = try call(context, "(j => Array.from(Wire.encodeOps(JSON.parse(j))))", [json])
            #expect(bytes(written) == swift, "\(name)")
        }
        let header = Wire.Header(kind: .change, flags: 3, length: 99, seq: 1 << 40, peer: 12)
        let written = try call(context, "(() => Array.from(Wire.encodeHeader({kind: 'change', flags: 3, length: 99, seq: 2 ** 40, peer: 12})))", [])
        #expect(bytes(written) == header.bytes)
        let read = try call(context, "(b => JSON.stringify(Wire.decodeHeader(Uint8Array.from(b))))", [header.bytes.map(Int.init)])
        #expect(read.toString() == #"{"kind":"change","flags":3,"length":99,"seq":1099511627776,"peer":12}"#)
    }

    @Test func theWebClientRejectsBadBytesToo() throws {
        let context = try webWire()
        let bytes = Wire.encode(unusual)
        let bads: [[UInt8]] = [Array(bytes.prefix(bytes.count / 2)), bytes + [0], [1, 9], [1, 1, 1, 1] + Array(repeating: [6, 1], count: 40).flatMap { $0 }]
        for bad in bads {
            #expect(throws: (any Error).self) { try Wire.decode(bad) }
            #expect(throws: (any Error).self) { _ = try call(context, "(b => Wire.decodeOps(Uint8Array.from(b)))", [bad.map(Int.init)]) }
        }
    }

    /// The relay's messages, as the web client reads and writes them.
    @Test func theWebClientSpeaksTheRelaysMessages() throws {
        let context = try webWire()
        let hello = try call(context, """
            (() => Array.from(Wire.encodeHello({ role: "view", room: "r", secret: "s", client: "c", applied: 4, name: "Ann" })))
            """, [])
        #expect(try Relay.Hello(bytes(hello)) == Relay.Hello(role: .view, room: "r", secret: "s", client: "c", applied: 4, name: Array("Ann".utf8)))
        let welcome = Relay.Welcome(peer: 3, room: "room", hostSecret: "h", limits: Relay.Limits(maxFrame: 5, maxSnapshot: 6, logBytes: 7, maxPeers: 8),
                                    latest: 9, version: 1, title: Array("Shop é".utf8), peers: [1: Array("Host".utf8), 2: []])
        let read = try call(context, "(b => { const w = Wire.decodeWelcome(Uint8Array.from(b)); w.peers = [...w.peers]; return JSON.stringify(w); })",
                            [welcome.frame.body.map(Int.init)])
        #expect(read.toString() == #"{"peer":3,"room":"room","limits":{"maxFrame":5,"maxSnapshot":6,"logBytes":7,"maxPeers":8},"latest":9,"version":1,"title":"Shop é","peers":[[1,"Host"],[2,""]]}"#)
        let decision = Relay.Decision(author: 2, cseq: 300, digest: Array(1...8), content: [9, 9])
        let readDecision = try call(context, "(b => { const d = Wire.decodeDecision(Uint8Array.from(b)); return JSON.stringify([d.author, d.cseq, Array.from(d.digest), Array.from(d.content)]); })",
                                    [decision.body.map(Int.init)])
        #expect(readDecision.toString() == "[2,300,[1,2,3,4,5,6,7,8],[9,9]]")
        let snapshot = Relay.Snapshot(digest: Array(0..<8), taken: [2: 4], entities: [["id": .string("a"), "kind": .string("table")]])
        let readSnapshot = try call(context, "(b => { const s = Wire.decodeSnapshot(Uint8Array.from(b)); return JSON.stringify([[...s.taken], s.entities]); })",
                                    [snapshot.body.map(Int.init)])
        #expect(readSnapshot.toString() == #"[[[2,4]],[{"id":"a","kind":"table"}]]"#)
        for presence in [Relay.Presence(cursor: [1.5, -2.25], selection: ["A", "B"]), Relay.Presence()] {
            let json = presence.cursor.map { "[\($0[0]),\($0[1])]" } ?? "null"
            let selection = String(decoding: try JSONEncoder().encode(presence.selection), as: UTF8.self)
            let written = try call(context, "(s => Array.from(Wire.encodePresence(JSON.parse(s))))",
                                   [#"{"cursor":\#(json),"selection":\#(selection)}"#])
            #expect(try Relay.Presence(bytes(written)) == presence)
            let back = try call(context, "(b => JSON.stringify(Wire.decodePresence(Uint8Array.from(b))))", [presence.body.map(Int.init)])
            #expect(back.toString() == #"{"cursor":\#(json),"selection":\#(selection)}"#)
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

    /// The web client opens what Swift seals, and Swift what it seals, in a real WebKit page: JavaScriptCore alone has
    /// no WebCrypto, and WebKit only offers it to a secure page, hence the https base.
    @MainActor @Test func theWebClientAndSwiftOpenEachOthersFrames() async throws {
        let page = WKWebView()
        page.loadHTMLString("<script>\(try wireScript())\nwindow.Wire = Wire;</script>", baseURL: URL(string: "https://joinery.test/"))
        for _ in 0..<250 where (try? await page.evaluateJavaScript("typeof Wire")) as? String != "object" {
            try await Task.sleep(for: .milliseconds(20))
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Array($0) }
        let plain = Wire.encode(unusual)
        let fromSwift = Wire.stamp(Wire.Frame(.ops, seq: 9, sealing: plain, with: key).bytes, peer: 1)
        var tampered = fromSwift
        tampered[8] ^= 1
        let result = try await page.callAsyncJavaScript("""
            const key = await Wire.importKey(Uint8Array.from(raw));
            const opened = await Wire.open(key, Uint8Array.from(fromSwift));
            const refused = await Wire.open(key, Uint8Array.from(tampered)).then(() => false, () => true);
            const sealed = await Wire.seal(key, { kind: "change", seq: 4 }, opened.body);
            return { kind: opened.header.kind, seq: opened.header.seq, body: Array.from(opened.body), refused, sealed: Array.from(sealed) };
            """, arguments: ["raw": raw, "fromSwift": fromSwift, "tampered": tampered], contentWorld: .page) as? [String: Any]
        let answer = try #require(result)
        #expect(answer["kind"] as? String == "ops" && answer["seq"] as? Int == 9)
        #expect((answer["body"] as? [NSNumber])?.map(\.uint8Value) == plain)
        #expect(answer["refused"] as? Bool == true)
        let fromWeb = try #require((answer["sealed"] as? [NSNumber])?.map(\.uint8Value))
        let frame = try Wire.Frame(Wire.stamp(fromWeb, peer: 2))
        #expect(frame.header.kind == .change && frame.header.seq == 4)
        #expect(try frame.opened(with: key) == plain)
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
