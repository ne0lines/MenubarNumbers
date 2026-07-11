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
