import CommonCrypto
import Foundation
import Security

/// How Chromium browsers on macOS encrypt cookies and passwords: a secret in the login keychain
/// ("<Browser> Safe Storage"), stretched with PBKDF2 into an AES-128 key, and "v10"-prefixed CBC blobs.
public enum SafeStorage {
    public enum KeychainError: Error, LocalizedError {
        case denied, missing, failed(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .denied: "access to the browser's Safe Storage wasn't allowed"
            case .missing: "the browser's Safe Storage key isn't in the keychain"
            case .failed(let status): "the keychain returned error \(status)"
            }
        }
    }

    public static func key(secret: Data) -> Data {
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        _ = key.withUnsafeMutableBytes { derived in
            secret.withUnsafeBytes { password in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: CChar.self),
                                     secret.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     derived.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        return key
    }

    /// The plaintext of a "v10" blob, or nil when it isn't one or doesn't decrypt with `key`.
    public static func decrypt(_ blob: Data, key: Data) -> Data? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8), key.count == 16 else { return nil }
        let cipher = Data(blob.dropFirst(3))
        guard cipher.count % 16 == 0 else { return nil }
        let iv = [UInt8](repeating: 0x20, count: 16)
        var plain = Data(count: cipher.count + 16)
        var length = 0
        let capacity = plain.count
        let status = plain.withUnsafeMutableBytes { output in
            cipher.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, 16, iv, input.baseAddress, cipher.count, output.baseAddress, capacity, &length)
                }
            }
        }
        return status == kCCSuccess ? plain.prefix(length) : nil
    }

    /// The browser's Safe Storage secret. macOS asks the user for their login password the first time.
    public static func secret(service: String, account: String) throws -> Data {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.missing }
            return data
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw KeychainError.denied
        case errSecItemNotFound: throw KeychainError.missing
        default: throw KeychainError.failed(status)
        }
    }
}

extension ImportBrowser {
    /// The keychain item holding this browser's Safe Storage secret.
    public var safeStorage: (service: String, account: String) {
        let name = switch self {
        case .arc: "Arc"
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        }
        return ("\(name) Safe Storage", name)
    }
}
