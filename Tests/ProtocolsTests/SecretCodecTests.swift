import Testing
@testable import Protocols

@Test
func secretEncodeOutputIsStable() throws {
    let encoded = _secretEncode("0000-0000-0000-000")

    #expect(encoded == "AWNcX0BdSR5jVU5CVURzQlRVUw")
    #expect(try _secretDecode(encoded) == "0000-0000-0000-000")
}

@Test
func secretCodecRoundTripsUnicodeStrings() throws {
    let original = "project-alpha: token 42, Привет"
    let encoded = SecretCodec.encode(original)

    #expect(try SecretCodec.decode(encoded) == original)
    #expect(SecretCodec.encode(original) == encoded)
}

@Test
func secretDecodeRejectsInvalidPayload() throws {
    #expect(throws: SecretCodecError.invalidPayload) {
        _ = try _secretDecode("xD@#32dX")
    }
}

@Test
func secretDecodeRejectsUnsupportedVersion() throws {
    #expect(throws: SecretCodecError.unsupportedVersion) {
        _ = try _secretDecode("Ag")
    }
}
