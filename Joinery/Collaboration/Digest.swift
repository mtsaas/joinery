import Foundation

/// A checksum of a whole replica that's kept up to date op by op, so the host can send it with every change and each
/// client can check its copy is the host's exactly. It's the sum of a hash of each entity, so it doesn't depend on
/// order and an entity's change only swaps its hash.
///
/// Each entity is hashed as its canonical JSON (`JSON.canonical`: what JavaScript's `JSON.stringify` writes, with keys
/// sorted), in UTF-8, by two 32-bit FNV-1a hashes with different starting values. Sums wrap at 2³². Written as 16 hex
/// digits, the first hash's sum then the second's. See docs/collaboration.md.
struct Digest: Equatable, CustomStringConvertible {
    private(set) var first: UInt32 = 0
    private(set) var second: UInt32 = 0

    init() {}

    init(_ entities: some Sequence<Replica.Entity>) {
        for entity in entities { add(entity) }
    }

    mutating func add(_ entity: Replica.Entity) {
        let (a, b) = Self.hash(entity)
        first &+= a
        second &+= b
    }

    mutating func remove(_ entity: Replica.Entity) {
        let (a, b) = Self.hash(entity)
        first &-= a
        second &-= b
    }

    var description: String { String(format: "%08x%08x", first, second) }

    static func hash(_ entity: Replica.Entity) -> (UInt32, UInt32) {
        var a: UInt32 = 2_166_136_261, b: UInt32 = 3_735_928_559
        for byte in JSON.object(entity).canonical.utf8 {
            a = (a ^ UInt32(byte)) &* 16_777_619
            b = (b ^ UInt32(byte)) &* 16_777_619
        }
        return (a, b)
    }
}

/// A replica with its digest, kept up to date as ops are applied: the copy a session's host and clients each keep of
/// what's been confirmed.
struct CheckedReplica: Equatable {
    private(set) var replica: Replica
    private(set) var digest: Digest

    init(_ replica: Replica = Replica()) {
        self.replica = replica
        digest = Digest(replica.entities.values)
    }

    /// Takes another's change as `Replica.receive` does, all of it, tidied after, or none.
    /// - Returns: The tidying ops it applied after the change's.
    mutating func receive(_ ops: [Replica.Op]) throws -> [Replica.Op] {
        var trial = replica
        let tidying = try trial.receive(ops)
        apply(ops)
        apply(tidying)
        return tidying
    }

    /// Applies `ops` as `Replica.apply` does, updating the digest by the entities each changes.
    mutating func apply(_ ops: [Replica.Op]) {
        for op in ops {
            let id = op.id
            if let old = replica.entities[id] { digest.remove(old) }
            _ = replica.apply(op)
            if let new = replica.entities[id] { digest.add(new) }
        }
    }
}

extension JSON {
    /// As JavaScript's `JSON.stringify` writes it, with every object's keys sorted by their UTF-16 code units: the same
    /// text in any language, for hashing.
    var canonical: String {
        switch self {
        case .null: "null"
        case .bool(let bool): bool ? "true" : "false"
        case .number(let number): Self.canonical(number)
        case .string(let string): Self.canonical(string)
        case .array(let array): "[" + array.map(\.canonical).joined(separator: ",") + "]"
        case .object(let object):
            "{" + object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
                .map { Self.canonical($0) + ":" + object[$0]!.canonical }.joined(separator: ",") + "}"
        }
    }

    /// A number as JavaScript writes it: the shortest digits that read back as it (which Swift's description has
    /// too), laid out by ECMAScript's Number::toString.
    static func canonical(_ number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number == 0 { return "0" }
        // Swift writes the same shortest digits, as "123.45", "1e-07" or "1.5e+20": take them apart.
        let text = String(describing: abs(number))
        var mantissa = Substring(text), exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            mantissa = text[..<e]
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        var digits = Array(parts[0] + (parts.count > 1 ? parts[1] : ""))
        // Where the decimal point falls, counting from the first digit.
        var point = parts[0].count + exponent
        while digits.count > 1, digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let k = digits.count, n = point, all = String(digits)
        let laidOut: String
        if k <= n, n <= 21 {
            laidOut = all + String(repeating: "0", count: n - k)
        } else if 0 < n, n <= 21 {
            laidOut = String(digits[..<n]) + "." + String(digits[n...])
        } else if -6 < n, n <= 0 {
            laidOut = "0." + String(repeating: "0", count: -n) + all
        } else {
            let e = n - 1
            laidOut = String(digits[0]) + (k > 1 ? "." + String(digits[1...]) : "") + "e" + (e >= 0 ? "+" : "-") + String(abs(e))
        }
        return (number < 0 ? "-" : "") + laidOut
    }

    /// A string as JavaScript writes it: quotes, backslashes and control characters escaped, the rest as it is.
    static func canonical(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
