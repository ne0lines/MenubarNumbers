import Foundation

public struct StreamDeckHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method.uppercased()
        self.path = path
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

public struct StreamDeckHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct StreamDeckBridgeError: Codable, Equatable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

public struct StreamDeckFieldsRequest: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let refresh: Bool

    public init(sourceID: UUID, refresh: Bool) {
        self.sourceID = sourceID
        self.refresh = refresh
    }
}

public struct StreamDeckSubscriptionRequest: Codable, Equatable, Sendable {
    public let clientID: String
    public let selections: Set<StreamDeckSelection>

    public init(clientID: String, selections: Set<StreamDeckSelection>) {
        self.clientID = clientID
        self.selections = selections
    }
}

public struct StreamDeckSnapshotRequest: Codable, Equatable, Sendable {
    public let selections: Set<StreamDeckSelection>

    public init(selections: Set<StreamDeckSelection>) {
        self.selections = selections
    }
}

public protocol StreamDeckBridgeBackend: Sendable {
    func sources() async -> [StreamDeckSourceSummary]
    func fields(sourceID: UUID, refresh: Bool) async -> [StreamDeckScalarField]
    func replaceSubscriptions(clientID: String, selections: Set<StreamDeckSelection>) async
    func snapshots(selections: Set<StreamDeckSelection>) async -> [StreamDeckSnapshot]
}

public struct StreamDeckBridgeRouter: Sendable {
    private let token: String
    private let backend: any StreamDeckBridgeBackend

    public init(token: String, backend: any StreamDeckBridgeBackend) {
        self.token = token
        self.backend = backend
    }

    public func route(_ request: StreamDeckHTTPRequest) async -> StreamDeckHTTPResponse {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return error(statusCode: 401, code: "unauthorized")
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/sources"):
            return json(statusCode: 200, value: await backend.sources())

        case ("POST", "/v1/fields"):
            guard let input = try? JSONDecoder().decode(StreamDeckFieldsRequest.self, from: request.body) else {
                return error(statusCode: 400, code: "invalid_request")
            }
            return json(
                statusCode: 200,
                value: await backend.fields(sourceID: input.sourceID, refresh: input.refresh)
            )

        case ("PUT", "/v1/subscriptions"):
            guard let input = try? JSONDecoder().decode(StreamDeckSubscriptionRequest.self, from: request.body),
                  !input.clientID.isEmpty else {
                return error(statusCode: 400, code: "invalid_request")
            }
            await backend.replaceSubscriptions(clientID: input.clientID, selections: input.selections)
            return StreamDeckHTTPResponse(statusCode: 204)

        case ("POST", "/v1/snapshots"):
            guard let input = try? JSONDecoder().decode(StreamDeckSnapshotRequest.self, from: request.body) else {
                return error(statusCode: 400, code: "invalid_request")
            }
            return json(statusCode: 200, value: await backend.snapshots(selections: input.selections))

        default:
            return error(statusCode: 404, code: "not_found")
        }
    }

    private func json<T: Encodable & Sendable>(statusCode: Int, value: T) -> StreamDeckHTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(value) else {
            return error(statusCode: 500, code: "internal_error")
        }
        return StreamDeckHTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    private func error(statusCode: Int, code: String) -> StreamDeckHTTPResponse {
        let body = (try? JSONEncoder().encode(StreamDeckBridgeError(code: code))) ?? Data()
        return StreamDeckHTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }
}
