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

        XCTAssertEqual(sensitiveKeys(in: jsonObject), [])
    }

    func testValidationRejectsURLWithUserInfo() {
        let request = APIRequestConfiguration(url: URL(string: "https://user:password@example.com/weather")!)

        XCTAssertThrowsError(try request.validate()) { error in
            XCTAssertEqual(error as? APIRequestConfigurationValidationError, .urlContainsUserInfo)
        }
    }

    func testValidationRejectsSensitiveHeaderAndQueryNamesRegardlessOfFormatting() {
        let headerRequest = APIRequestConfiguration(
            url: URL(string: "https://api.example.com/weather")!,
            headers: ["X_API-Key": "not-persisted"]
        )
        let queryRequest = APIRequestConfiguration(
            url: URL(string: "https://api.example.com/weather")!,
            queryItems: [APIRequestQueryItem(name: "ACCESS-token", value: "not-persisted")]
        )

        XCTAssertThrowsError(try headerRequest.validate()) { error in
            XCTAssertEqual(
                error as? APIRequestConfigurationValidationError,
                .prohibitedField(name: "X_API-Key", location: .header)
            )
        }
        XCTAssertThrowsError(try queryRequest.validate()) { error in
            XCTAssertEqual(
                error as? APIRequestConfigurationValidationError,
                .prohibitedField(name: "ACCESS-token", location: .queryItem)
            )
        }
    }

    func testValidationRejectsSensitiveJSONBodyKeysRecursively() {
        let request = APIRequestConfiguration(
            method: .post,
            url: URL(string: "https://api.example.com/weather")!,
            jsonBody: "{\"filters\": [{\"client_secret\": \"not-persisted\"}]}"
        )

        XCTAssertThrowsError(try request.validate()) { error in
            XCTAssertEqual(
                error as? APIRequestConfigurationValidationError,
                .prohibitedField(name: "client_secret", location: .jsonBody)
            )
        }
    }

    func testValidationAcceptsStaticNonCredentialRequestData() throws {
        let request = APIRequestConfiguration(
            method: .post,
            url: URL(string: "https://api.example.com/weather")!,
            headers: ["Accept": "application/json"],
            queryItems: [APIRequestQueryItem(name: "unit", value: "metric")],
            jsonBody: "{\"filters\": [{\"city\": \"Stockholm\"}]}"
        )

        XCTAssertNoThrow(try request.validate())
    }

    func testEncodingRejectsCredentialBearingRequestConfiguration() {
        let request = APIRequestConfiguration(
            url: URL(string: "https://api.example.com/weather")!,
            headers: ["Authorization": "not-persisted"]
        )

        XCTAssertThrowsError(try JSONEncoder().encode(request)) { error in
            XCTAssertEqual(
                error as? APIRequestConfigurationValidationError,
                .prohibitedField(name: "Authorization", location: .header)
            )
        }
    }

    private func sensitiveKeys(in jsonObject: Any) -> [String] {
        if let dictionary = jsonObject as? [String: Any] {
            return dictionary.flatMap { key, value in
                let keyResult = isSensitive(key) ? [key] : []
                return keyResult + sensitiveKeys(in: value)
            }
        }

        if let array = jsonObject as? [Any] {
            return array.flatMap(sensitiveKeys(in:))
        }

        return []
    }

    private func isSensitive(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if ["authentication", "credentialreference"].contains(normalized) {
            return false
        }
        let prohibitedFragments = [
            "authorization", "apikey", "token", "secret", "password", "credential", "bearer", "privatekey", "accesskey"
        ]
        return normalized == "auth" || prohibitedFragments.contains { normalized.contains($0) }
    }
}
