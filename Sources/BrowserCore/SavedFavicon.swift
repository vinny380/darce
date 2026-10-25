import Foundation

/// A tab's icon, saved with the tab (Arc shows Favorites' and pins' icons before their pages load).
struct SavedFavicon: Codable, Equatable, Sendable {
    let profileID: UUID
    let png: Data

    /// Small, well-formed PNGs only: the signature, an IHDR chunk with a correct checksum, 1–128 px a side.
    static func isAcceptablePNG(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 33, bytes.count <= 262_144,
              Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(bytes[12..<16]) == Array("IHDR".utf8), number(bytes, at: 8) == 13 else { return false }
        let width = number(bytes, at: 16), height = number(bytes, at: 20)
        guard (1...128).contains(width), (1...128).contains(height) else { return false }
        return crc32(bytes[12..<29]) == number(bytes, at: 29)
    }

    private static func number(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static let table: [UInt32] = (0..<256).map { value in
        (0..<8).reduce(UInt32(value)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        ~bytes.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
