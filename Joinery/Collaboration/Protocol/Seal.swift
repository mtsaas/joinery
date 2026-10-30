#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Bodies sealed with the room key, which the relay never has (see `docs/relay.md`): AES-256-GCM, the body written as
/// nonce, ciphertext and tag, with the header authenticated alongside. The relay writes the header's `peer`, so that's
/// zeroed when authenticating; anything else a relay changes makes the frame fail to open.
extension Wire.Frame {
    /// What sealing adds to a body: a 12-byte nonce and a 16-byte tag.
    static let sealing = 28

    init(_ kind: Wire.Kind, seq: UInt64 = 0, sealing plain: [UInt8], with key: SymmetricKey) {
        header = Wire.Header(kind: kind, length: UInt32(plain.count + Self.sealing), seq: seq)
        // ponytail: random nonces; fine for far more frames than a room's 2^32 limit.
        body = Array(try! AES.GCM.seal(plain, using: key, authenticating: header.bytes).combined!)
    }

    func opened(with key: SymmetricKey) throws(Wire.Malformed) -> [UInt8] {
        var header = header
        header.peer = 0
        guard let box = try? AES.GCM.SealedBox(combined: body),
              let plain = try? AES.GCM.open(box, using: key, authenticating: header.bytes)
        else { throw Wire.Malformed("a message that doesn't open with the room's key") }
        return Array(plain)
    }
}
