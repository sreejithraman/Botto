import Foundation
import Testing
@testable import BottoCore

@Test nonisolated func jsonValueSerializesSendableValuesInDetachedTasks() async throws {
    let source = Data(#"{"text":"Hello 🌶️","number":42.5,"flag":true,"nothing":null,"items":[1,false,"two"],"nested":{"key":"value"}}"#.utf8)
    let value: JSONValue = .object([
        "text": .string("Hello 🌶️"), "number": .number(42.5), "flag": .bool(true), "nothing": .null,
        "items": .array([.number(1), .bool(false), .string("two")]),
        "nested": .object(["key": .string("value")])
    ])
    let (decoded, encoded, modified) = try await Task.detached {
        var copy = value
        copy["text"] = .string("Changed")
        return (try JSONValue.decode(source), try value.data, copy)
    }.value

    #expect(decoded == value)
    // Compare JSON objects so wire-key order is irrelevant; the fixture is independent of the codec.
    #expect(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary == JSONSerialization.jsonObject(with: source) as? NSDictionary)
    #expect(value["text"].text == "Hello 🌶️")
    #expect(modified["text"].text == "Changed")
}

@Test nonisolated func jsonValuePreservesSerializationFailuresInDetachedTasks() async {
    await #expect(throws: ConversationServiceError.incompatible) {
        try await Task.detached { try JSONValue.decode(Data("{invalid".utf8)) }.value
    }
    await #expect(throws: EncodingError.self) {
        try await Task.detached { try JSONValue.number(.infinity).data }.value
    }
}

@Test nonisolated func jsonValuePreservesWireScalarTypesAndUnicode() throws {
    let source = Data(#"{"zero":0,"one":1,"fraction":-12.5,"exponent":1.2e3,"yes":true,"no":false,"nothing":null,"text":"true","tokens":["🙂","e\u0301",0,false]}"#.utf8)
    let expected: JSONValue = .object([
        "zero": .number(0), "one": .number(1), "fraction": .number(-12.5), "exponent": .number(1200),
        "yes": .bool(true), "no": .bool(false), "nothing": .null, "text": .string("true"),
        "tokens": .array([.string("🙂"), .string("e\u{301}"), .number(0), .bool(false)])
    ])
    #expect(try JSONValue.decode(source) == expected)
    #expect(try JSONValue.decode(Data("true".utf8)) == .bool(true))
    #expect(try JSONValue.decode(Data("1".utf8)) == .number(1))
    #expect(try JSONValue.decode(Data("null".utf8)) == .null)
    #expect(try JSONValue.decode(Data(#"{"key":1,"key":2}"#.utf8))["key"] == .number(1))
    #expect(try JSONValue.decode(#"{"text":"Hello 🙂"}"#.data(using: .utf16LittleEndian)!) == .object(["text": .string("Hello 🙂")]))
}

@Test(arguments: ["{invalid", "1e400", "NaN", #"{"text":"\uD800"}"#])
nonisolated func jsonValueRejectsInvalidWireValues(source: String) {
    #expect(throws: ConversationServiceError.incompatible) { try JSONValue.decode(Data(source.utf8)) }
}

@Test nonisolated func jsonValueKeepsFirstCanonicalKeyInNestedWireObjects() throws {
    let source = Data(#"{"payload":{"é":1,"e\u0301":2},"items":[{"key":3,"key":4}]}"#.utf8)
    #expect(try JSONValue.decode(source) == .object([
        "payload": .object(["é": .number(1)]), "items": .array([.object(["key": .number(3)])])
    ]))
}
