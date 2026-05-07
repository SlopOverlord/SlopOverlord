import Foundation

public enum SecretCodecError: Error, Equatable, Sendable {
    case invalidPayload
    case unsupportedVersion
    case invalidUTF8
}

public enum SecretCodec {
    private static let version: UInt8 = 1
    private static let key = Array("Sloppy.SecretCodec.v1".utf8)

    public static func encode(_ value: String) -> String {
        let obfuscated = Array(value.utf8).enumerated().map { index, byte in
            byte ^ key[index % key.count]
        }
        return base64URLEncode([version] + obfuscated)
    }

    public static func decode(_ encoded: String) throws -> String {
        let bytes = try base64URLDecode(encoded)
        guard let encodedVersion = bytes.first else {
            throw SecretCodecError.invalidPayload
        }
        guard encodedVersion == version else {
            throw SecretCodecError.unsupportedVersion
        }

        let decoded = bytes.dropFirst().enumerated().map { index, byte in
            byte ^ key[index % key.count]
        }
        guard let value = String(bytes: decoded, encoding: .utf8) else {
            throw SecretCodecError.invalidUTF8
        }
        return value
    }

    private static func base64URLEncode(_ bytes: [UInt8]) -> String {
        Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) throws -> [UInt8] {
        guard !value.isEmpty else {
            throw SecretCodecError.invalidPayload
        }
        guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw SecretCodecError.invalidPayload
        }

        let remainder = value.count % 4
        guard remainder != 1 else {
            throw SecretCodecError.invalidPayload
        }

        let padding = remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + padding

        guard let data = Data(base64Encoded: base64) else {
            throw SecretCodecError.invalidPayload
        }
        return Array(data)
    }
}

public func _secretEncode(_ value: String) -> String {
    SecretCodec.encode(value)
}

public func _secretDecode(_ encoded: String) throws -> String {
    try SecretCodec.decode(encoded)
}
