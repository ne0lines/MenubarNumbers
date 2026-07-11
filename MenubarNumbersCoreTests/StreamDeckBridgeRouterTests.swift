import XCTest
@testable import MenubarNumbersCore

final class StreamDeckBridgeRouterTests: XCTestCase {
    func testRejectsMissingBearerToken() async {
        let router = StreamDeckBridgeRouter(token: "secret", backend: BridgeBackendStub())

        let response = await router.route(
            StreamDeckHTTPRequest(method: "GET", path: "/v1/sources", headers: [:], body: Data())
        )

        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(response.headers["Content-Type"], "application/json")
    }

    func testRoutesAuthenticatedSourceList() async throws {
        let source = StreamDeckSourceSummary(
            id: UUID(), name: "Weather", isEnabled: true,
            hasResponse: false, lastSuccess: nil, error: nil
        )
        let router = StreamDeckBridgeRouter(token: "secret", backend: BridgeBackendStub(sources: [source]))

        let response = await router.route(authenticated(method: "GET", path: "/v1/sources"))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            try isoDecoder().decode([StreamDeckSourceSummary].self, from: response.body),
            [source]
        )
    }

    func testRoutesFieldRefresh() async throws {
        let sourceID = UUID()
        let field = StreamDeckScalarField(
            sourceID: sourceID, jsonPointer: "/count", label: "count",
            type: .number, value: "7", numericValue: 7
        )
        let backend = BridgeBackendStub(fields: [field])
        let router = StreamDeckBridgeRouter(token: "secret", backend: backend)
        let body = try JSONEncoder().encode(StreamDeckFieldsRequest(sourceID: sourceID, refresh: true))

        let response = await router.route(authenticated(method: "POST", path: "/v1/fields", body: body))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try isoDecoder().decode([StreamDeckScalarField].self, from: response.body), [field])
        let request = await backend.lastFieldsRequest
        XCTAssertEqual(request?.sourceID, sourceID)
        XCTAssertEqual(request?.refresh, true)
    }

    func testRoutesSubscriptionsAndSnapshots() async throws {
        let selection = StreamDeckSelection(sourceID: UUID(), jsonPointer: "/count", displayMode: .sparkline)
        let snapshot = StreamDeckSnapshot(
            selection: selection, type: .number, value: "7", numericValue: 7,
            history: [], status: .fresh, updatedAt: Date(timeIntervalSince1970: 10)
        )
        let backend = BridgeBackendStub(snapshots: [snapshot])
        let router = StreamDeckBridgeRouter(token: "secret", backend: backend)
        let subscriptionBody = try JSONEncoder().encode(
            StreamDeckSubscriptionRequest(clientID: "client", selections: [selection])
        )

        let subscriptionResponse = await router.route(
            authenticated(method: "PUT", path: "/v1/subscriptions", body: subscriptionBody)
        )
        let snapshotBody = try JSONEncoder().encode(StreamDeckSnapshotRequest(selections: [selection]))
        let snapshotResponse = await router.route(
            authenticated(method: "POST", path: "/v1/snapshots", body: snapshotBody)
        )
        let subscriptionClientID = await backend.lastSubscriptionClientID
        let subscriptionSelections = await backend.lastSubscriptionSelections

        XCTAssertEqual(subscriptionResponse.statusCode, 204)
        XCTAssertEqual(subscriptionClientID, "client")
        XCTAssertEqual(subscriptionSelections, [selection])
        XCTAssertEqual(snapshotResponse.statusCode, 200)
        XCTAssertEqual(try isoDecoder().decode([StreamDeckSnapshot].self, from: snapshotResponse.body), [snapshot])
    }

    func testMalformedJSONAndUnknownRouteReturnStableErrors() async throws {
        let router = StreamDeckBridgeRouter(token: "secret", backend: BridgeBackendStub())

        let malformed = await router.route(
            authenticated(method: "POST", path: "/v1/fields", body: Data("{".utf8))
        )
        let unknown = await router.route(authenticated(method: "GET", path: "/v1/unknown"))

        XCTAssertEqual(malformed.statusCode, 400)
        XCTAssertEqual(unknown.statusCode, 404)
        XCTAssertEqual(try JSONDecoder().decode(StreamDeckBridgeError.self, from: malformed.body).code, "invalid_request")
        XCTAssertEqual(try JSONDecoder().decode(StreamDeckBridgeError.self, from: unknown.body).code, "not_found")
    }

    private func authenticated(method: String, path: String, body: Data = Data()) -> StreamDeckHTTPRequest {
        StreamDeckHTTPRequest(
            method: method,
            path: path,
            headers: ["authorization": "Bearer secret"],
            body: body
        )
    }

    private func isoDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private actor BridgeBackendStub: StreamDeckBridgeBackend {
    let sourceValues: [StreamDeckSourceSummary]
    let fieldValues: [StreamDeckScalarField]
    let snapshotValues: [StreamDeckSnapshot]
    private(set) var lastFieldsRequest: (sourceID: UUID, refresh: Bool)?
    private(set) var lastSubscriptionClientID: String?
    private(set) var lastSubscriptionSelections: Set<StreamDeckSelection> = []

    init(
        sources: [StreamDeckSourceSummary] = [],
        fields: [StreamDeckScalarField] = [],
        snapshots: [StreamDeckSnapshot] = []
    ) {
        sourceValues = sources
        fieldValues = fields
        snapshotValues = snapshots
    }

    func sources() async -> [StreamDeckSourceSummary] { sourceValues }

    func fields(sourceID: UUID, refresh: Bool) async -> [StreamDeckScalarField] {
        lastFieldsRequest = (sourceID, refresh)
        return fieldValues
    }

    func replaceSubscriptions(clientID: String, selections: Set<StreamDeckSelection>) async {
        lastSubscriptionClientID = clientID
        lastSubscriptionSelections = selections
    }

    func snapshots(selections: Set<StreamDeckSelection>) async -> [StreamDeckSnapshot] {
        snapshotValues
    }
}
