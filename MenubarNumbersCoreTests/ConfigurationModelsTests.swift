import XCTest
@testable import MenubarNumbersCore

final class ConfigurationModelsTests: XCTestCase {
    func testDataPointDefaultsFallbackToEmDash() {
        let dataPoint = DataPoint(
            sourceID: UUID(),
            jsonPointer: "/weather/temperature",
            label: "Temperature"
        )

        XCTAssertEqual(dataPoint.fallback, "—")
    }

    func testLayoutPreservesItemOrder() {
        let first = DataPoint(sourceID: UUID(), jsonPointer: "/first", label: "First")
        let second = DataPoint(sourceID: UUID(), jsonPointer: "/second", label: "Second")
        let layout = MenuBarLayout(items: [second, first])

        XCTAssertEqual(layout.items.map(\.id), [second.id, first.id])
    }

    func testEncodedSourceContainsNoCredentialSecretFields() throws {
        let source = APISource(
            name: "Weather",
            request: APIRequestConfiguration(url: URL(string: "https://api.example.com/weather")!),
            authentication: .basic(credentialReference: UUID())
        )

        let data = try JSONEncoder().encode(source)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.contains("\\\"password\\\""))
        XCTAssertFalse(encoded.contains("\\\"token\\\""))
        XCTAssertFalse(encoded.contains("\\\"secret\\\""))
        XCTAssertFalse(encoded.contains("\\\"apiKeyValue\\\""))
    }
}
