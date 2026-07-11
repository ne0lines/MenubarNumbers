import XCTest
@testable import MenubarNumbersCore

final class StreamDeckBridgeModelsTests: XCTestCase {
    func testCatalogueContainsOnlySortedScalarFieldsWithEscapedPointers() throws {
        let sourceID = UUID()
        let response = JSONValue.object([
            "nested/key": .object(["count~today": .number(Decimal(string: "12.5")!)]),
            "enabled": .bool(true),
            "object": .object([:])
        ])

        let fields = StreamDeckScalarCatalogue.fields(sourceID: sourceID, response: response)

        XCTAssertEqual(fields.map(\.jsonPointer), ["/enabled", "/nested~1key/count~0today"])
        XCTAssertEqual(fields[0].type, .boolean)
        XCTAssertEqual(fields[0].value, "true")
        XCTAssertNil(fields[0].numericValue)
        XCTAssertEqual(fields[1].type, .number)
        XCTAssertEqual(fields[1].numericValue, 12.5)
    }

    func testBridgeDTOEncodingCannotContainRequestConfiguration() throws {
        let source = StreamDeckSourceSummary(
            id: UUID(),
            name: "Weather",
            isEnabled: true,
            hasResponse: true,
            lastSuccess: Date(timeIntervalSince1970: 10),
            error: nil
        )

        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)

        XCTAssertFalse(encoded.contains("url"))
        XCTAssertFalse(encoded.contains("header"))
        XCTAssertFalse(encoded.contains("authentication"))
        XCTAssertFalse(encoded.contains("credential"))
    }
}
