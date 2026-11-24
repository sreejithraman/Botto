import Foundation
import Testing
@testable import BottoCore

@Suite struct T3PairingTests {
    @Test func savedConnectionsRemainCompatible() throws {
        let legacy = Data("""
        {"id":"C75A3620-B1A1-4CEE-8EE1-DE2BAC826FEF","serverURL":"https://hermes.example",
         "username":"user","password":"value","connectionHeaders":{}}
        """.utf8)
        var configuration = try JSONDecoder().decode(ConnectionConfiguration.self, from: legacy)
        #expect(configuration.t3 == nil)
        configuration.t3 = T3Connection(environmentID: "environment", label: "Host", accessToken: "bearer",
                                         projectID: "project", workspaceRoot: "/home/botto", providerInstanceID: "codex", model: "model")
        let roundTrip = try JSONDecoder().decode(ConnectionConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(roundTrip == configuration)
    }

    @Test func acceptsDirectPairingInputs() throws {
        let origin = try #require(URL(string: "https://host.example:1234"))
        let link = try T3PairingExchange.parse("https://host.example:1234/pair#token=a%2Bb")
        #expect(link.origin == origin)
        #expect(link.credential == "a+b")
        #expect(try T3PairingExchange.parse("t3code://pair?url=https%3A%2F%2Fhost.example%3A1234&credential=a%2Bb") == link)
        #expect(try T3PairingExchange.parse("t3code://pair?pairingUrl=https%3A%2F%2Fhost.example%3A1234%2Fpair%23token%3Da%252Bb") == link)
        #expect(try T3PairingExchange.parse(origin.absoluteString, credential: "a+b") == link)
        #expect(throws: T3PairingError.invalidOrigin) {
            try T3PairingExchange.parse("file:///tmp", credential: "token")
        }
    }
}

extension T3PairingTests {
    @Test func exchangesTheCredentialAndMintsAnRPCTicket() async throws {
        let origin = try #require(URL(string: "https://host.example"))
        let exchange = T3PairingExchange { request in
            let url = try #require(request.url)
            let body: String
            switch url.path {
            case "/.well-known/t3/environment":
                #expect(request.httpMethod == "GET")
                body = #"{"environmentId":"env","label":"Host","serverVersion":"2.0","orchestrationProtocolVersion":2}"#
            case "/oauth/token":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                let encoded = String(decoding: try #require(request.httpBody), as: UTF8.self)
                #expect(Set(encoded.split(separator: "&").map(String.init)) == [
                    "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange",
                    "subject_token=a%2Bb%3Dc",
                    "subject_token_type=urn%3At3%3Aparams%3Aoauth%3Atoken-type%3Aenvironment-bootstrap",
                    "requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token",
                    "client_label=Botto+iOS", "client_device_type=mobile", "client_os=ios"
                ])
                body = #"{"token_type":"Bearer","access_token":"access"}"#
            case "/api/auth/websocket-ticket/rpc":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
                body = #"{"ticket":"short","expiresAt":"2026-11-24T12:34:56.123Z"}"#
            default: Issue.record("Unexpected request: \(url.path)"); body = ""
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let paired = try await exchange.exchangePairingCredential(origin: origin, credential: "a+b=c", clientLabel: "Botto iOS")
        #expect(paired.environmentDescriptor.orchestrationProtocolVersion == 2)
        #expect(paired.configuration.t3?.environmentID == "env")
        #expect(paired.configuration.t3?.accessToken == "access")
        #expect(try await exchange.mintWebSocketTicket(origin: origin, accessToken: paired.accessToken).ticket == "short")
    }

    @Test func rejectsOldProtocolAndCredentialRedirects() async throws {
        let origin = try #require(URL(string: "https://host.example"))
        let old = T3PairingExchange { request in
            let url = try #require(request.url)
            return (Data(#"{"orchestrationProtocolVersion":1}"#.utf8),
                    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        await #expect(throws: T3PairingError.incompatibleProtocol) { try await old.probeEnvironment(origin: origin) }

        let redirect = T3PairingExchange { request in
            let url = try #require(request.url)
            let body = #"{"environmentId":"env","label":"Host","serverVersion":"2.0","orchestrationProtocolVersion":2}"#
            let status = request.httpMethod == "POST" ? 307 : 200
            let headers = status == 307 ? ["Location": "https://other.example"] : nil
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
        }
        await #expect(throws: T3PairingError.redirected) {
            try await redirect.exchangePairingCredential(origin: origin, credential: "code", clientLabel: "Botto")
        }
        await #expect(throws: T3PairingError.redirected) {
            try await redirect.mintWebSocketTicket(origin: origin, accessToken: "access")
        }
    }
}
