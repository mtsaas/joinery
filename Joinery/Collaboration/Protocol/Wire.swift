import Foundation

/// The binary form of session messages (see `docs/relay.md`): a fixed 24-byte header a relay reads in place, then a
/// body only clients read. The body of a change is its ops, written compactly: known field names as one byte, IDs as 16
/// bytes, lengths as varints. The same ops always give the same bytes, so two implementations can be compared byte for
/// byte. The web client reads and writes the same bytes (`WebClient.html`, the `wire` script).
enum Wire {
    static let version: UInt8 = 1

    enum Kind: UInt8, CaseIterable {
        case hello = 1, ops, reject, change, snapshot, snapshotRequest, presence, ping, pong, joined, left, bye
    }

    struct Header: Equatable {
        static let size = 24
        var kind: Kind
        var flags: UInt16 = 0
        /// How many bytes of body follow.
        var length: UInt32
        /// Host frames: the change's number. A ping: the sender's last applied change. A change: its cseq.
        var seq: UInt64 = 0
        /// A guest's frame: the sender, stamped by the relay.
        var peer: UInt32 = 0

        var bytes: [UInt8] {
            var out = [Wire.version, kind.rawValue]
            out.reserveCapacity(Self.size)
            out.append(littleEndian: flags)
            out.append(littleEndian: length)
            out.append(littleEndian: seq)
            out.append(littleEndian: peer)
            out.append(littleEndian: UInt32(0))
            return out
        }

        init(kind: Kind, flags: UInt16 = 0, length: UInt32, seq: UInt64 = 0, peer: UInt32 = 0) {
            self.kind = kind
            self.flags = flags
            self.length = length
            self.seq = seq
            self.peer = peer
        }

        /// The header at the start of `bytes`.
        init(_ bytes: some Collection<UInt8>) throws(Malformed) {
            var reader = Reader(Array(bytes.prefix(Self.size)))
            guard try reader.byte() == Wire.version else { throw Malformed("an unknown version") }
            guard let kind = Kind(rawValue: try reader.byte()) else { throw Malformed("an unknown kind of message") }
            self.kind = kind
            flags = try reader.integer()
            length = try reader.integer()
            seq = try reader.integer()
            peer = try reader.integer()
            let _: UInt32 = try reader.integer()
        }
    }

    struct Malformed: Error, Equatable {
        let what: String
        init(_ what: String) { self.what = what }
    }

    // MARK: Ops

    /// Field names that fit in a byte. Codes are never reused or renumbered; new fields get the next one. Code 0 means
    /// the name follows in full, as any field not here is written.
    static let fields = [
        "id", "kind", "order", "name", "position", "color", "group", "notes", "samples", "table", "type",
        "isPrimaryKey", "isNullable", "isUnique", "from", "to", "zipTies", "direction", "heldDirection",
        "relationships", "column", "side", "along",
    ]
    private static let fieldCodes = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($1, UInt8($0 + 1)) })

    private enum Tag: UInt8 { case null, `false`, `true`, number, string, uuid, array, object }
    private enum OpTag: UInt8 { case put = 1, set, delete }

    static func encode(_ ops: [Replica.Op]) -> [UInt8] {
        var out: [UInt8] = []
        out.appendVarint(ops.count)
        for op in ops {
            switch op {
            case .put(let entity):
                out.append(OpTag.put.rawValue)
                out.appendVarint(entity.count)
                for name in entity.keys.sorted(by: utf16Order) {
                    appendField(name, to: &out)
                    append(entity[name]!, to: &out)
                }
            case .set(let id, let field, let value):
                out.append(OpTag.set.rawValue)
                append(.string(id), to: &out)
                appendField(field, to: &out)
                append(value, to: &out)
            case .delete(let id):
                out.append(OpTag.delete.rawValue)
                append(.string(id), to: &out)
            }
        }
        return out
    }

    static func decode(_ bytes: [UInt8]) throws(Malformed) -> [Replica.Op] {
        var reader = Reader(bytes)
        let count = try reader.count()
        var ops: [Replica.Op] = []
        ops.reserveCapacity(count)
        for _ in 0..<count {
            switch OpTag(rawValue: try reader.byte()) {
            case .put:
                var entity = Replica.Entity(minimumCapacity: 16)
                for _ in 0..<(try reader.count()) {
                    let name = try reader.field()
                    entity[name] = try reader.value()
                }
                ops.append(.put(entity))
            case .set:
                guard case .string(let id) = try reader.value() else { throw Malformed("an ID that isn't a string") }
                let field = try reader.field()
                ops.append(.set(id: id, field: field, value: try reader.value()))
            case .delete:
                guard case .string(let id) = try reader.value() else { throw Malformed("an ID that isn't a string") }
                ops.append(.delete(id: id))
            case nil:
                throw Malformed("an unknown op")
            }
        }
        guard reader.isAtEnd else { throw Malformed("bytes after the last op") }
        return ops
    }

    private static func utf16Order(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

    private static func appendField(_ name: String, to out: inout [UInt8]) {
        if let code = fieldCodes[name] {
            out.append(code)
        } else {
            out.append(0)
            out.appendString(name)
        }
    }

    private static func append(_ value: JSON, to out: inout [UInt8]) {
        switch value {
        case .null: out.append(Tag.null.rawValue)
        case .bool(let bool): out.append((bool ? Tag.true : Tag.false).rawValue)
        case .number(let number):
            out.append(Tag.number.rawValue)
            out.append(littleEndian: number.bitPattern)
        case .string(let string):
            // Only an uppercase UUID, as IDs are written, reads back as the same string.
            if string.utf8.count == 36, let uuid = UUID(uuidString: string), uuid.uuidString == string {
                out.append(Tag.uuid.rawValue)
                withUnsafeBytes(of: uuid.uuid) { out.append(contentsOf: $0) }
            } else {
                out.append(Tag.string.rawValue)
                out.appendString(string)
            }
        case .array(let array):
            out.append(Tag.array.rawValue)
            out.appendVarint(array.count)
            for element in array { append(element, to: &out) }
        case .object(let object):
            out.append(Tag.object.rawValue)
            out.appendVarint(object.count)
            for key in object.keys.sorted(by: utf16Order) {
                out.appendString(key)
                append(object[key]!, to: &out)
            }
        }
    }

    /// Reads what's written above, checking every length against what's left, so bad bytes throw and never trap.
    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        /// How deeply arrays and objects nest, bounded so bad bytes can't overflow the stack.
        var depth = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { index == bytes.count }

        mutating func byte() throws(Malformed) -> UInt8 {
            guard index < bytes.count else { throw Malformed("too few bytes") }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func take(_ n: Int) throws(Malformed) -> ArraySlice<UInt8> {
            guard n >= 0, n <= bytes.count - index else { throw Malformed("too few bytes") }
            defer { index += n }
            return bytes[index..<index + n]
        }

        mutating func integer<T: FixedWidthInteger & UnsignedInteger>() throws(Malformed) -> T {
            var value: T = 0
            for (shift, byte) in try take(MemoryLayout<T>.size).enumerated() { value |= T(byte) << (shift * 8) }
            return value
        }

        mutating func varint() throws(Malformed) -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                let byte = try byte()
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
            }
            throw Malformed("a number too long")
        }

        /// A count of things to follow, each at least a byte, so a count can't be more than what's left.
        mutating func count() throws(Malformed) -> Int {
            let count = try varint()
            guard count <= UInt64(bytes.count - index) else { throw Malformed("a count past the end") }
            return Int(count)
        }

        mutating func string() throws(Malformed) -> String {
            let length = try count()
            guard let string = String(validating: try take(length), as: UTF8.self) else { throw Malformed("text that isn't UTF-8") }
            return string
        }

        mutating func field() throws(Malformed) -> String {
            let code = try byte()
            if code == 0 { return try string() }
            guard Int(code) <= Wire.fields.count else { throw Malformed("an unknown field") }
            return Wire.fields[Int(code) - 1]
        }

        mutating func value() throws(Malformed) -> JSON {
            switch Tag(rawValue: try byte()) {
            case .null: return .null
            case .false: return .bool(false)
            case .true: return .bool(true)
            case .number: return .number(Double(bitPattern: try integer()))
            case .string: return .string(try string())
            case .uuid:
                let raw = Array(try take(16))
                let uuid = UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                                       raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
                return .string(uuid.uuidString)
            case .array:
                depth += 1
                defer { depth -= 1 }
                guard depth <= 32 else { throw Malformed("values nested too deeply") }
                var array: [JSON] = []
                for _ in 0..<(try count()) { array.append(try value()) }
                return .array(array)
            case .object:
                depth += 1
                defer { depth -= 1 }
                guard depth <= 32 else { throw Malformed("values nested too deeply") }
                var object: [String: JSON] = [:]
                for _ in 0..<(try count()) {
                    let key = try string()
                    object[key] = try value()
                }
                return .object(object)
            case nil:
                throw Malformed("an unknown kind of value")
            }
        }
    }
}

private extension [UInt8] {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendVarint(_ value: Int) {
        var value = UInt64(value)
        while value >= 0x80 {
            append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        append(UInt8(value))
    }

    mutating func appendString(_ string: String) {
        appendVarint(string.utf8.count)
        append(contentsOf: string.utf8)
    }
}
