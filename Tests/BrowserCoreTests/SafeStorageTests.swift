import Foundation
import Testing
@testable import BrowserCore

/// Chromium's "Safe Storage" encryption. Vectors come from Python's hashlib and the openssl CLI, not from this code.
private func hex(_ string: String) -> Data {
    Data(stride(from: 0, to: string.count, by: 2).map { offset in
        let start = string.index(string.startIndex, offsetBy: offset)
        return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
    })
}

@Test func derivesChromiumsKey() {
    #expect(SafeStorage.key(secret: Data("peanuts".utf8)) == hex("d9a09d499b4e1b7461f28e67972c6dbd"))
}

@Test func decryptsAKnownV10Blob() {
    let key = hex("d9a09d499b4e1b7461f28e67972c6dbd")
    #expect(SafeStorage.decrypt(hex("7631309bd03a621a677aee473d22749524af3d"), key: key) == Data("hello cookie".utf8))
}

@Test func wrongKeyDoesNotDecrypt() {
    let wrong = SafeStorage.key(secret: Data("not the secret".utf8))
    let plain = SafeStorage.decrypt(hex("7631309bd03a621a677aee473d22749524af3d"), key: wrong)
    #expect(plain != Data("hello cookie".utf8))
}

@Test func nonV10BlobIsRejected() {
    let key = hex("d9a09d499b4e1b7461f28e67972c6dbd")
    #expect(SafeStorage.decrypt(hex("7631319bd03a621a677aee473d22749524af3d"), key: key) == nil)   // "v11"
    #expect(SafeStorage.decrypt(Data("v10".utf8), key: key) == nil)
}

@Test func safeStorageNamesMatchEachBrowser() {
    #expect(ImportBrowser.arc.safeStorage == ("Arc Safe Storage", "Arc"))
    #expect(ImportBrowser.chrome.safeStorage == ("Chrome Safe Storage", "Chrome"))
    #expect(ImportBrowser.edge.safeStorage == ("Microsoft Edge Safe Storage", "Microsoft Edge"))
    #expect(ImportBrowser.brave.safeStorage == ("Brave Safe Storage", "Brave"))
}
