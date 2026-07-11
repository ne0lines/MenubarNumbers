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

    func testSnapshotBuilderKeepsValueAndHistoryWhenSourceIsStale() {
        let sourceID = UUID()
        let selection = StreamDeckSelection(
            sourceID: sourceID,
            jsonPointer: "/count",
            displayMode: .sparkline
        )
        let history = [StreamDeckHistorySample(timestamp: Date(timeIntervalSince1970: 5), value: 6)]

        let snapshot = StreamDeckSnapshotBuilder.snapshot(
            selection: selection,
            response: .object(["count": .number(7)]),
            history: history,
            isStale: true,
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(snapshot.type, .number)
        XCTAssertEqual(snapshot.value, "7")
        XCTAssertEqual(snapshot.numericValue, 7)
        XCTAssertEqual(snapshot.history, history)
        XCTAssertEqual(snapshot.status, .stale)
    }

    func testSnapshotBuilderMarksMissingOrNonScalarPointers() {
        let sourceID = UUID()
        let selection = StreamDeckSelection(
            sourceID: sourceID,
            jsonPointer: "/nested",
            displayMode: .value
        )

        let snapshot = StreamDeckSnapshotBuilder.snapshot(
            selection: selection,
            response: .object(["nested": .object([:])]),
            history: [],
            isStale: false,
            updatedAt: nil
        )

        XCTAssertNil(snapshot.type)
        XCTAssertNil(snapshot.value)
        XCTAssertEqual(snapshot.status, .missing)
    }
}
