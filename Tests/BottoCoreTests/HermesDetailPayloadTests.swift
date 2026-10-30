import Foundation
import Testing
@testable import BottoCore

@Test func hermesDetailsDecodeToolContentWithoutLosingMetadata() {
    let raw = ###"{"content":"## Native daily worker\n\nFiles updated.","success":true}"###
    let sections = HermesDetailPayload.sections(raw)

    #expect(sections.map(\.text) == ["## Native daily worker\n\nFiles updated.", "{\n  \"success\": true\n}"])
    #expect(sections.map(\.format) == [.markdown, .json])
}

@Test func hermesDetailsPreserveJSONTokensAndEscapedStrings() {
    let raw = #"[{"id":1234567890123456789012345678901234567890,"id":-0.00e+12,"literal":"a, b: {c} \\\"quoted\\\"","empty":[]}]"#
    let sections = HermesDetailPayload.sections(raw)

    #expect(sections.count == 1)
    #expect(sections[0].format == .json)
    #expect(sections[0].text.contains("1234567890123456789012345678901234567890"))
    #expect(sections[0].text.contains("-0.00e+12"))
    #expect(sections[0].text.components(separatedBy: "\"id\"").count == 3)
    #expect((try? JSONSerialization.jsonObject(with: Data(sections[0].text.utf8))) != nil)
}

@Test func hermesDetailsDecodeNestedResultStrings() throws {
    let nested = #"{"result":{"output":"first\nsecond","exit_code":0},"ok":true}"#
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["result": nested]), as: UTF8.self)
    let sections = HermesDetailPayload.sections(raw)

    #expect(sections.contains { $0.format == .markdown && $0.text == "first\nsecond" })
    #expect(sections.contains { $0.format == .json && $0.text.contains("\"exit_code\": 0") })
    #expect(sections.contains { $0.format == .json && $0.text.contains("\"ok\": true") })
}

@Test(arguments: ["  ordinary\\ntext  ", "{broken", "[1,]", "true", "42", #""quoted\ntext""#, "{\"n\": NaN}"])
func hermesDetailsPreserveUnstructuredInputExactly(raw: String) {
    let sections = HermesDetailPayload.sections(raw)
    #expect(sections.count == 1)
    #expect(sections[0].text == raw)
    #expect(sections[0].format == .plain)
}

@Test func hermesDetailsBoundOversizedAndDeepInput() {
    let oversized = "{\"content\":\"" + String(repeating: "é", count: 132_000) + "\"}"
    let deep = String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)
    for raw in [oversized, deep] {
        #expect(HermesDetailPayload.sections(raw).map(\.text) == [raw])
        #expect(HermesDetailPayload.sections(raw).map(\.format) == [.plain])
    }
}

@Test func hermesDetailsBoundNestedStringWrappers() throws {
    var raw = #"{"content":"text"}"#
    for _ in 0..<8 {
        raw = String(decoding: try JSONSerialization.data(withJSONObject: ["result": raw]), as: UTF8.self)
    }
    let sections = HermesDetailPayload.sections(raw)
    #expect(sections.count == 1)
    #expect(sections[0].format == .json)
    #expect(sections[0].text.contains("result"))
}

@Test func hermesDetailsUnwrapTextBlocksAndRetainNonTextBlocks() {
    let raw = #"{"content":[{"type":"text","text":"Read\nthis"},{"type":"image_url","image_url":{"url":"https://example.com/a.png"}}]}"#
    let sections = HermesDetailPayload.sections(raw)

    #expect(sections.contains { $0.format == .markdown && $0.text == "Read\nthis" })
    #expect(sections.contains { $0.format == .json && $0.text.contains("https://example.com/a.png") })
    #expect(sections.contains { $0.format == .json && $0.text.contains("\"type\": \"text\"") })
}
