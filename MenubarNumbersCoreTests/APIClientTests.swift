import Foundation
import XCTest
@testable import MenubarNumbersCore

final class APIClientTests: XCTestCase {
    func testFetchResolvesConfiguredRequestValuesAndBearerAuthentication() async throws {
        let store = InMemorySecureValueStore()
        let headerReference = UUID()
        let queryReference = UUID()
        let bodyReference = UUID()
        let bearerReference = UUID()
        try store.set("client-secret", for: headerReference)
        try store.set("10", for: queryReference)
        try store.set(#"{"metric":true}"#, for: bodyReference)
        try store.set("bearer-secret", for: bearerReference)
        let transport = RecordingTransport(response: .json(#"{"temp":21}"#))
        let client = APIClient(transport: transport, secureValueStore: store)
        let source = APISource(
            name: "Weather",
            request: APIRequestConfiguration(
                method: .post,
                url: URL(string: "https://api.example.com/weather")!,
                headers: [RequestHeader(name: "X-Client", valueReference: headerReference)],
                queryItems: [RequestQueryItem(name: "limit", valueReference: queryReference)],
                jsonBodyReference: bodyReference
            ),
            authentication: .bearer(credentialReference: bearerReference)
        )

        let result = try await client.fetch(source: source)
        XCTAssertEqual(result, .object(["temp": .number(21)]))
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client"), "client-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpBody, Data(#"{"metric":true}"#.utf8))
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "limit", value: "10")])
    }

    func testFetchBuildsBase64BasicAuthorization() async throws {
        let store = InMemorySecureValueStore()
        let credentialReference = UUID()
        try store.set("alicia:correct-horse", for: credentialReference)
        let transport = RecordingTransport(response: .json(#"{"ok":true}"#))
        let client = APIClient(transport: transport, secureValueStore: store)
        let source = APISource(
            name: "Protected",
            request: APIRequestConfiguration(url: URL(string: "https://api.example.com/protected")!),
            authentication: .basic(credentialReference: credentialReference)
        )

        _ = try await client.fetch(source: source)

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic YWxpY2lhOmNvcnJlY3QtaG9yc2U=")
    }

    func testFetchComposesConfiguredQueryWithAPIKeyQueryAuthentication() async throws {
        let store = InMemorySecureValueStore()
        let configuredQueryReference = UUID()
        let apiKeyReference = UUID()
        try store.set("forecast", for: configuredQueryReference)
        try store.set("query-secret", for: apiKeyReference)
        let transport = RecordingTransport(response: .json(#"{"ok":true}"#))
        let client = APIClient(transport: transport, secureValueStore: store)
        let source = APISource(
            name: "Weather",
            request: APIRequestConfiguration(
                url: URL(string: "https://api.example.com/weather")!,
                queryItems: [RequestQueryItem(name: "mode", valueReference: configuredQueryReference)]
            ),
            authentication: .apiKeyQuery(name: "api_key", credentialReference: apiKeyReference)
        )

        _ = try await client.fetch(source: source)

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "mode", value: "forecast"), URLQueryItem(name: "api_key", value: "query-secret")]
        )
    }

    func testFetchResolvesAPIKeyHeaderAuthentication() async throws {
        let store = InMemorySecureValueStore()
        let apiKeyReference = UUID()
        try store.set("header-secret", for: apiKeyReference)
        let transport = RecordingTransport(response: .json(#"{"ok":true}"#))
        let client = APIClient(transport: transport, secureValueStore: store)
        let source = APISource(
            name: "Weather",
            request: APIRequestConfiguration(url: URL(string: "https://api.example.com/weather")!),
            authentication: .apiKeyHeader(name: "X-API-Key", credentialReference: apiKeyReference)
        )

        _ = try await client.fetch(source: source)

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "header-secret")
    }

    func testFetchMapsHTTPAndInvalidJSONResponsesWithoutLeakingSecrets() async throws {
        let store = InMemorySecureValueStore()
        let transport = RecordingTransport(response: HTTPTransportResponse(statusCode: 401, data: Data(#"{"error":"unauthorized"}"#.utf8)))
        let client = APIClient(transport: transport, secureValueStore: store)
        let source = APISource(name: "Protected", request: APIRequestConfiguration(url: URL(string: "https://api.example.com/protected")!))

        do {
            _ = try await client.fetch(source: source)
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error as? APIClientError, .httpStatus(401))
            XCTAssertFalse((error.localizedDescription).contains("unauthorized"))
        }

        await transport.setResponse(.json("not json"))
        do {
            _ = try await client.fetch(source: source)
            XCTFail("Expected invalid JSON error")
        } catch {
            XCTAssertEqual(error as? APIClientError, .invalidJSONResponse)
        }
    }

    func testFetchMapsMissingAndInvalidSecureValuesWithoutLeakingTheirContents() async throws {
        let store = InMemorySecureValueStore()
        let missingReference = UUID()
        let bodyReference = UUID()
        try store.set("super-secret-not-json", for: bodyReference)
        let transport = RecordingTransport(response: .json(#"{"ok":true}"#))
        let client = APIClient(transport: transport, secureValueStore: store)
        let base = URL(string: "https://api.example.com/values")!

        let missingSource = APISource(name: "Missing", request: APIRequestConfiguration(url: base, headers: [RequestHeader(name: "X-Key", valueReference: missingReference)]))
        do {
            _ = try await client.fetch(source: missingSource)
            XCTFail("Expected missing secure value")
        } catch {
            XCTAssertEqual(error as? APIClientError, .missingSecureValue)
            XCTAssertFalse(error.localizedDescription.contains(missingReference.uuidString))
        }

        let invalidBodySource = APISource(name: "Bad body", request: APIRequestConfiguration(method: .post, url: base, jsonBodyReference: bodyReference))
        do {
            _ = try await client.fetch(source: invalidBodySource)
            XCTFail("Expected invalid configured JSON")
        } catch {
            XCTAssertEqual(error as? APIClientError, .invalidConfiguredJSONBody)
            XCTAssertFalse(error.localizedDescription.contains("super-secret-not-json"))
        }
    }

    func testFetchMapsTransportFailuresToNetworkError() async throws {
        let client = APIClient(transport: FailingTransport(), secureValueStore: InMemorySecureValueStore())
        let source = APISource(name: "Offline", request: APIRequestConfiguration(url: URL(string: "https://api.example.com/offline")!))

        do {
            _ = try await client.fetch(source: source)
            XCTFail("Expected network error")
        } catch {
            XCTAssertEqual(error as? APIClientError, .network)
        }
    }
}

private actor RecordingTransport: HTTPTransport {
    private var response: HTTPTransportResponse
    private var requests: [URLRequest] = []

    init(response: HTTPTransportResponse) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        return response
    }

    func lastRequest() -> URLRequest? { requests.last }

    func setResponse(_ response: HTTPTransportResponse) { self.response = response }
}

private extension HTTPTransportResponse {
    static func json(_ string: String, statusCode: Int = 200) -> Self {
        Self(statusCode: statusCode, data: Data(string.utf8))
    }
}

private struct FailingTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> HTTPTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}
