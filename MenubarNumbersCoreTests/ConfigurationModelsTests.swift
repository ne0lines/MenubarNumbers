import XCTest
@testable import MenubarNumbersCore

final class ConfigurationModelsTests: XCTestCase {
    func testRequestGenerationOnlyAcceptsTheMostRecentRequestForASource() {
        let sourceID = UUID()
        var generations = SourceRequestGenerations()

        let first = generations.begin(for: sourceID)
        let second = generations.begin(for: sourceID)

        XCTAssertFalse(generations.isCurrent(first, for: sourceID))
        XCTAssertTrue(generations.isCurrent(second, for: sourceID))
        XCTAssertFalse(generations.isCurrent(second, for: UUID()))
    }

    func testRequestGenerationInvalidationRejectsAnInFlightRequestAfterSourceDeletion() {
        let sourceID = UUID()
        var generations = SourceRequestGenerations()
        let inFlightGeneration = generations.begin(for: sourceID)

        generations.invalidate(sourceID)

        XCTAssertFalse(generations.isCurrent(inFlightGeneration, for: sourceID))
    }

    func testRequestGenerationInvalidationRejectsAnInFlightRequestBeforeSameIDSourceReplacement() {
        let sourceID = UUID()
        var generations = SourceRequestGenerations()
        let requestForOldConfiguration = generations.begin(for: sourceID)

        // AppState invalidates before replacing a source's metadata, so an old
        // endpoint or credential set cannot publish into the replacement.
        generations.invalidate(sourceID)
        let requestForReplacement = generations.begin(for: sourceID)

        XCTAssertFalse(generations.isCurrent(requestForOldConfiguration, for: sourceID))
        XCTAssertTrue(generations.isCurrent(requestForReplacement, for: sourceID))
    }

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

    func testMenuBarRendererUsesLayoutOrderTemplateAndSeparator() {
        let sourceID = UUID()
        let temperature = DataPoint(
            sourceID: sourceID,
            jsonPointer: "/temperature",
            label: "Temp",
            format: "{label}: {value}",
            numberDecimalPlaces: 1
        )
        let online = DataPoint(
            sourceID: sourceID,
            jsonPointer: "/online",
            label: "Online",
            format: "{value}"
        )
        let layout = MenuBarLayout(separator: " | ", items: [temperature, online])

        let result = MenuBarTextRenderer.render(
            layout: layout,
            responses: [sourceID: .object(["temperature": .number(Decimal(213)), "online": .bool(true)])]
        )

        XCTAssertEqual(result, "Temp: 21.3 | true")
    }

    func testMenuBarRendererScalesIntegerValuesByConfiguredDecimals() {
        let sourceID = UUID()
        let point = DataPoint(
            sourceID: sourceID,
            jsonPointer: "/value",
            label: "Value",
            format: "{value}",
            numberDecimalPlaces: 2
        )

        let result = MenuBarTextRenderer.render(
            layout: MenuBarLayout(items: [point]),
            responses: [sourceID: .object(["value": .number(Decimal(12345))])]
        )

        XCTAssertEqual(result, "123.45")

        let leadingZeroResult = MenuBarTextRenderer.render(
            layout: MenuBarLayout(items: [point]),
            responses: [sourceID: .object(["value": .number(12)])]
        )

        XCTAssertEqual(leadingZeroResult, "0.12")
    }

    func testMenuBarRendererExposesEachRenderedItemForTheMenu() {
        let sourceID = UUID()
        let first = DataPoint(sourceID: sourceID, jsonPointer: "/first", label: "First")
        let second = DataPoint(sourceID: sourceID, jsonPointer: "/second", label: "Second", format: "{value}")
        let layout = MenuBarLayout(items: [first, second])

        let result = MenuBarTextRenderer.renderItems(
            layout: layout,
            responses: [sourceID: .object(["first": .number(12), "second": .string("ready")])]
        )

        XCTAssertEqual(result, ["First 12", "ready"])
    }

    func testMenuBarRendererUsesFallbackForMissingOrNonScalarValue() {
        let sourceID = UUID()
        let missing = DataPoint(sourceID: sourceID, jsonPointer: "/missing", label: "Missing", fallback: "N/A")
        let object = DataPoint(sourceID: sourceID, jsonPointer: "/nested", label: "Nested", fallback: "—")
        let layout = MenuBarLayout(separator: " · ", items: [missing, object])

        let result = MenuBarTextRenderer.render(
            layout: layout,
            responses: [sourceID: .object(["nested": .object([:])])]
        )

        XCTAssertEqual(result, "Missing N/A · Nested —")
    }

    func testMenuBarRendererFormatsISO8601DateWithSelectedDateStyle() {
        let sourceID = UUID()
        let point = DataPoint(
            sourceID: sourceID,
            jsonPointer: "/updated",
            label: "Updated",
            format: "{value}",
            dateStyle: .short
        )

        let result = MenuBarTextRenderer.render(
            layout: MenuBarLayout(items: [point]),
            responses: [sourceID: .object(["updated": .string("2026-07-11T12:30:00Z")])]
        )

        XCTAssertEqual(result, "2026-07-11")
    }

    func testEncodedSourceContainsNoCredentialSecretFields() throws {
        let source = APISource(
            name: "Weather",
            request: APIRequestConfiguration(url: URL(string: "https://api.example.com/weather")!),
            authentication: .basic(credentialReference: UUID())
        )

        let data = try JSONEncoder().encode(source)
        let jsonObject = try JSONSerialization.jsonObject(with: data)

        XCTAssertEqual(
            allObjectKeys(in: jsonObject),
            [
                "authentication", "basic", "credentialReference", "headers", "id", "isEnabled", "method", "name",
                "queryItems", "refreshInterval", "request", "url"
            ]
        )
    }

    func testBaseURLValidationRejectsUserInfo() {
        let request = APIRequestConfiguration(url: URL(string: "https://user:password@example.com/weather")!)

        XCTAssertThrowsError(try JSONEncoder().encode(request)) { error in
            XCTAssertEqual(error as? APIRequestConfigurationValidationError, .urlContainsUserInfo)
        }
    }

    func testBaseURLValidationRejectsQuery() {
        let request = APIRequestConfiguration(
            url: URL(string: "https://api.example.com/weather?unit=metric")!
        )

        XCTAssertThrowsError(try JSONEncoder().encode(request)) { error in
            XCTAssertEqual(error as? APIRequestConfigurationValidationError, .urlContainsQuery)
        }
    }

    func testDecodingRejectsBaseURLWithQuery() {
        let encodedRequest = """
        {"method":"GET","url":"https://api.example.com/weather?unit=metric","headers":[],"queryItems":[],"refreshInterval":60}
        """

        XCTAssertThrowsError(try JSONDecoder().decode(APIRequestConfiguration.self, from: Data(encodedRequest.utf8))) { error in
            XCTAssertEqual(error as? APIRequestConfigurationValidationError, .urlContainsQuery)
        }
    }

    func testDecodingRejectsBaseURLWithUserInfo() {
        let encodedRequest = """
        {"method":"GET","url":"https://user:password@api.example.com/weather","headers":[],"queryItems":[],"refreshInterval":60}
        """

        XCTAssertThrowsError(try JSONDecoder().decode(APIRequestConfiguration.self, from: Data(encodedRequest.utf8))) { error in
            XCTAssertEqual(error as? APIRequestConfigurationValidationError, .urlContainsUserInfo)
        }
    }

    func testRequestEncodingPersistsOnlyReferenceMetadata() throws {
        let headerReference = UUID()
        let queryReference = UUID()
        let bodyReference = UUID()
        let request = APIRequestConfiguration(
            method: .post,
            url: URL(string: "https://api.example.com/weather")!,
            headers: [RequestHeader(name: "X-API-Key", valueReference: headerReference)],
            queryItems: [RequestQueryItem(name: "api_key", valueReference: queryReference)],
            jsonBodyReference: bodyReference
        )

        let data = try JSONEncoder().encode(request)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedHeaders = try XCTUnwrap(jsonObject["headers"] as? [[String: Any]])
        let encodedQueryItems = try XCTUnwrap(jsonObject["queryItems"] as? [[String: Any]])

        XCTAssertEqual(Set(try XCTUnwrap(encodedHeaders.first).keys), ["name", "valueReference"])
        XCTAssertEqual(Set(try XCTUnwrap(encodedQueryItems.first).keys), ["name", "valueReference"])
        XCTAssertNil(jsonObject["value"])
        XCTAssertNil(jsonObject["jsonBody"])

        let decoded = try JSONDecoder().decode(APIRequestConfiguration.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testCredentialNamedRequestReferencesAreAllowed() {
        let request = APIRequestConfiguration(
            url: URL(string: "https://api.example.com/weather")!,
            headers: [RequestHeader(name: "Authorization", valueReference: UUID())],
            queryItems: [RequestQueryItem(name: "access_token", valueReference: UUID())]
        )

        XCTAssertNoThrow(try request.validate())
    }

    func testHTTPSAndExplicitLoopbackHTTPURLsArePermitted() {
        let urls = [
            "https://api.example.com/weather",
            "http://localhost:8080/weather",
            "http://127.0.0.1:8080/weather",
            "http://[::1]:8080/weather"
        ]

        for value in urls {
            let request = APIRequestConfiguration(url: URL(string: value)!)
            XCTAssertNoThrow(try request.validate(), "Expected permitted URL: \(value)")
        }
    }

    func testURLPolicyRejectsRemoteHTTPAndUnsupportedSchemes() {
        let remoteHTTP = APIRequestConfiguration(url: URL(string: "http://api.example.com/weather")!)
        XCTAssertThrowsError(try remoteHTTP.validate()) { error in
            XCTAssertEqual(error as? APIRequestConfigurationValidationError, .insecureHTTPHost)
        }

        let fileURL = APIRequestConfiguration(url: URL(string: "file:///tmp/weather.json")!)
        XCTAssertThrowsError(try fileURL.validate()) { error in
            XCTAssertEqual(error as? APIRequestConfigurationValidationError, .unsupportedURLScheme)
        }
    }

    private func allObjectKeys(in jsonObject: Any) -> [String] {
        if let dictionary = jsonObject as? [String: Any] {
            return dictionary.flatMap { key, value in
                [key] + allObjectKeys(in: value)
            }.sorted()
        }

        if let array = jsonObject as? [Any] {
            return array.flatMap(allObjectKeys(in:)).sorted()
        }

        return []
    }
}
