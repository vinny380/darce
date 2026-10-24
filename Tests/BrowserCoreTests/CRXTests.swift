import Foundation
import Testing
@testable import BrowserCore

/// Chrome Web Store downloads are CRX files: "Cr24", a version, a signed header, then a plain zip.
/// Each test names the bug it catches.
private func crx(version: UInt32, header: Data, zip: Data) -> Data {
    var data = Data("Cr24".utf8)
    for value in [version, UInt32(header.count)] { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    return data + header + zip
}

private let zip = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 7, count: 20)

@Test func crx3PayloadIsTheZipAfterTheHeader() throws {
    #expect(try CRXFile.zipPayload(crx(version: 3, header: Data(repeating: 1, count: 37), zip: zip)) == zip)
}

@Test func notACRXIsRejectedNotMisread() {
    #expect(throws: CRXFile.Error.notCRX) { try CRXFile.zipPayload(Data("<html>Not found</html>".utf8)) }
}

@Test func truncatedHeaderIsRejectedWithoutCrashing() {
    let file = crx(version: 3, header: Data(repeating: 1, count: 37), zip: zip)
    #expect(throws: CRXFile.Error.truncated) { try CRXFile.zipPayload(file.prefix(30)) }
}

@Test func payloadThatIsNotAZipIsRejected() {
    #expect(throws: CRXFile.Error.notZip) { try CRXFile.zipPayload(crx(version: 3, header: Data(count: 4), zip: Data("garbage".utf8))) }
}

@Test func unsupportedCRX2IsRejected() {
    #expect(throws: CRXFile.Error.unsupportedVersion(2)) { try CRXFile.zipPayload(crx(version: 2, header: Data(count: 4), zip: zip)) }
}

/// Store links come in several shapes; all name the same 32-letter extension id.
@Test func chromeWebStoreLinksAndBareIdsResolveToTheExtensionId() {
    let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
    #expect(CRXFile.extensionID(from: "https://chromewebstore.google.com/detail/dark-reader/\(id)") == id)
    #expect(CRXFile.extensionID(from: "https://chrome.google.com/webstore/detail/dark-reader/\(id)?hl=en") == id)
    #expect(CRXFile.extensionID(from: id) == id)
    #expect(CRXFile.extensionID(from: "https://example.com/not-an-extension") == nil)
}
