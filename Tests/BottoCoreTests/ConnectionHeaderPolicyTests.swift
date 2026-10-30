import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [
    ["Authorization": "Bearer example"],
    ["Cookie": "example=value"],
    ["CF-Access-Client-Id": ""],
    ["CF-Access-Client-Id": "a", "cf-access-client-id": "b"],
    ["CF-Access-Client-Secret": "line\r\nInjected: value"],
    ["CF-Access-Client-Secret": "tab\tvalue"],
    ["CF-Access-Client-Secret": "delete\u{7f}"],
    ["CF-Access-Client-Secret": "nonascii-é"],
    ["CF-Access-Client-Secret": String(repeating: "a", count: 4_097)]
]) func bothConnectionBoundariesRejectInvalidProxyHeaders(_ headers: [String: String]) throws {
    let url = URL(string: "https://hermes.example")!, transport = ScriptedTransport()
    #expect(throws: HermesServiceError.invalidAddress) {
        try HermesHTTPConnection(configuration: ConnectionConfiguration(serverURL: url, connectionHeaders: headers), transport: transport)
    }
    #expect(throws: PairingAddress.Failure.invalidAddress) {
        try NativeSignInExchange(serverURL: url, connectionHeaders: headers, transport: transport)
    }
    #expect(transport.requests.isEmpty)
}

@MainActor @Test func bothConnectionBoundariesAcceptPrintableASCIIAtHeaderLimit() throws {
    let url = URL(string: "https://hermes.example")!, transport = ScriptedTransport()
    let headers = ["cF-aCcEsS-cLiEnT-Id": " !~", "CF-Access-Client-Secret": String(repeating: "a", count: 4_096)]
    let http = try HermesHTTPConnection(configuration: ConnectionConfiguration(serverURL: url, connectionHeaders: headers), transport: transport)
    let native = try NativeSignInExchange(serverURL: url, connectionHeaders: headers, transport: transport)
    defer { http.retire(); native.close() }
    #expect(http.configuration.connectionHeaders == headers)
    #expect(native.serverURL == url)
}
