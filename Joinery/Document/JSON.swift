import Foundation

/// Any JSON value, as entities' fields are.
enum JSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSON].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
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
