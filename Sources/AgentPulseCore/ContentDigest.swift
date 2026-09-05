import CryptoKit
import Foundation

enum ContentDigest {
    private static let hexadecimalDigits = Array("0123456789abcdef".utf8)
    private static let digitsPerByte = 2
    private static let nibbleBits = 4
    private static let nibbleMask: UInt8 = 0x0F

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var encoded = [UInt8](repeating: 0, count: SHA256.Digest.byteCount * digitsPerByte)
        var index = 0
        for byte in digest {
            encoded[index] = hexadecimalDigits[Int(byte >> nibbleBits)]
            encoded[index + 1] = hexadecimalDigits[Int(byte & nibbleMask)]
            index += digitsPerByte
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }
}
