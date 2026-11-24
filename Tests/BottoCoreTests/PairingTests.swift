import Foundation
import Testing
@testable import BottoCore

@Test(arguments: [
    "", "https://", "https:example.com", "https:///example.com", "ftp://example.com",
    "https://user:password@example.com", "https://user@example.com", "https://example.com?token=private",
    "https://example.com?", "https://example.com#private", "https://example.com#",
    "https://example.com/api", "https://example.com/..", "https://example.com/%2e%2e",
    "https://example.com/%2f", "https://example.com/%5c", "https://example.com/%",
    "https://example.com/%GG", "https://example.com/%00", "https://example.com:0",
    "https://example.com:65536", "https://example.com:", "https://example.com:abc",
    "https://example.com\\@evil.example", " https://example.com", "https://example.com\n",
    "https://exam\tple.com", "https://example.com\u{7f}", "https://example.com\u{200b}",
    "https://%65xample.com", "https://example..com", "https://-example.com", "https://[garbage]",
    "https://127.1", "https://999.999.999.999",
    "t3code://pair", "custom://connect"
]) func pairingRejectsUntrustedInput(_ input: String) {
    #expect(throws: (any Error).self) { try PairingAddress.parse(input) }
}

@Test func pairingNormalizesOrigins() throws {
    #expect(try PairingAddress.parse("https://BOTTO.example/").absoluteString == "https://botto.example")
    #expect(try PairingAddress.parse("https://[::1]:9119").absoluteString == "https://[::1]:9119")
    #expect(try PairingAddress.parse("https://my-host.trycloudflare.com").host == "my-host.trycloudflare.com")
    #expect(try PairingAddress.parse("https://192.168.1.2").host == "192.168.1.2")
}

@Test func pairingHTTPNeedsExplicitConsent() throws {
    #expect(throws: PairingAddress.Failure.insecureHTTP) { try PairingAddress.parse("http://192.168.1.2:9119") }
    #expect(try PairingAddress.parse("http://192.168.1.2:9119", allowInsecureHTTP: true).absoluteString
        == "http://192.168.1.2:9119")
    #expect(throws: PairingAddress.Failure.insecureHTTP) {
        try PairingAddress.parse("http://public.example", allowInsecureHTTP: true)
    }
    #expect(throws: PairingAddress.Failure.insecureHTTP) {
        try PairingAddress.parse("http://example.10.0.0.1", allowInsecureHTTP: true)
    }
    #expect(throws: PairingAddress.Failure.insecureHTTP) {
        try PairingAddress.parse("http://[fc::1]", allowInsecureHTTP: true)
    }
}

@Test func pairingBoundsInputWithoutDiscardingSecrets() {
    #expect(throws: PairingAddress.Failure.tooLong) {
        try PairingAddress.parse("https://botto.example/" + String(repeating: "x", count: 4_096))
    }
    #expect(throws: PairingAddress.Failure.tooLong) {
        try PairingAddress.parse(String(repeating: "🦀", count: 1_025))
    }
    #expect(throws: PairingAddress.Failure.unsupportedPath) { try PairingAddress.parse("https://botto.example/private-token") }
}
