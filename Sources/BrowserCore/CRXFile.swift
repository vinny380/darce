import Foundation

/// Chrome Web Store packages: "Cr24", a version, a signed header, then a plain zip of the extension.
public enum CRXFile {
    public enum Error: Swift.Error, Equatable {
        case notCRX, truncated, notZip, unsupportedVersion(UInt32)
    }

    /// The zip inside a CRX3 file. The signature isn't checked: the file comes straight from the store over HTTPS.
    public static func zipPayload(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, Array(bytes[0..<4]) == Array("Cr24".utf8) else { throw Error.notCRX }
        guard bytes.count >= 12 else { throw Error.truncated }
        let version = UInt32(littleEndian: bytes[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard version == 3 else { throw Error.unsupportedVersion(version) }
        let headerSize = Int(UInt32(littleEndian: bytes[8..<12].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        let start = 12 + headerSize
        guard bytes.count > start else { throw Error.truncated }
        guard bytes.count >= start + 4, Array(bytes[start..<start + 4]) == [0x50, 0x4B, 0x03, 0x04] else { throw Error.notZip }
        return Data(bytes[start...])
    }

    /// The 32-letter (a–p) id from a Chrome Web Store link, or the id itself.
    public static func extensionID(from text: String) -> String? {
        let candidates = text.split(whereSeparator: { "/?#&=".contains($0) }).map(String.init)
        return candidates.last { $0.count == 32 && $0.allSatisfy { ("a"..."p").contains($0) } }
    }

    /// Where Chrome itself downloads a store extension.
    public static func downloadURL(forExtensionID id: String) -> URL {
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=131.0&acceptformat=crx3&x=id%3D\(id)%26uc")!
    }
}
