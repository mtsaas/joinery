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
