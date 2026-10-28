import Foundation

/// Keys that sort things in order, as strings compared character by character, from which a key can always be made
/// between any two: "a" < "ai" < "b". Made of 0–9 and a–z, never ending in 0, so there's always room before one.
enum OrderKey {
    private static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static let values = Dictionary(uniqueKeysWithValues: digits.enumerated().map { ($1, $0) })

    /// Whether it's a key one could have made: something else in an `order` field is replaced.
    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 256 && key.last != "0" && key.allSatisfy { values[$0] != nil }
    }

    /// A key after `low` and before `high`, or after `low` with nothing after it; "" is before everything.
    static func between(_ low: String, _ high: String?) -> String {
        let low = Array(low), high = high.map(Array.init)
        var key = "", isBounded = high != nil, index = 0
        while true {
            let a = index < low.count ? values[low[index]] ?? 0 : 0
            let b = isBounded && index < high!.count ? values[high![index]] ?? digits.count : digits.count
            if b - a > 1 {
                key.append(digits[(a + b) / 2])
                return key
            }
            key.append(digits[a])
            // Below `high` now, so free of it from here.
            if b - a == 1 { isBounded = false }
            index += 1
        }
    }

    /// `count` keys in order between `low` and `high`, spread out so later inserts among them stay short.
    static func spread(_ count: Int, after low: String, before high: String?) -> [String] {
        guard count > 0 else { return [] }
        let middle = between(low, high), half = (count - 1) / 2
        return spread(half, after: low, before: middle) + [middle] + spread(count - 1 - half, after: middle, before: high)
    }
}
