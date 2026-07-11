import Foundation

public enum MenubarNumbersCore {}

public enum HTTPMethod: String, Codable, Sendable {
    case get = "GET"
    case post = "POST"
}

/// A persisted header name and the Keychain reference for its value.
public struct RequestHeader: Codable, Equatable, Sendable {
    public var name: String
    public var valueReference: UUID

    public init(name: String, valueReference: UUID) {
        self.name = name
        self.valueReference = valueReference
    }
}

/// A persisted query-item name and the Keychain reference for its value.
public struct RequestQueryItem: Codable, Equatable, Sendable {
    public var name: String
    public var valueReference: UUID

    public init(name: String, valueReference: UUID) {
        self.name = name
        self.valueReference = valueReference
    }
}

public enum APIRequestConfigurationValidationError: Error, Equatable, LocalizedError, Sendable {
    case urlContainsUserInfo
    case urlContainsQuery

    public var errorDescription: String? {
        switch self {
        case .urlContainsUserInfo:
            return "Request URLs cannot include user information. Store credentials in Keychain instead."
        case .urlContainsQuery:
            return "Request URLs cannot include query items. Store each query value in Keychain instead."
        }
    }
}

/// Persisted request metadata. All user-supplied request values are stored in
/// Keychain and represented here only by UUID references.
public struct APIRequestConfiguration: Codable, Equatable, Sendable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [RequestHeader]
    public var queryItems: [RequestQueryItem]
    public var jsonBodyReference: UUID?
    public var refreshInterval: TimeInterval

    public init(
        method: HTTPMethod = .get,
        url: URL,
        headers: [RequestHeader] = [],
        queryItems: [RequestQueryItem] = [],
        jsonBodyReference: UUID? = nil,
        refreshInterval: TimeInterval = 60
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.queryItems = queryItems
        self.jsonBodyReference = jsonBodyReference
        self.refreshInterval = refreshInterval
    }

    /// Rejects base URLs that would persist request values outside Keychain.
    public func validate() throws {
        guard url.user == nil, url.password == nil else {
            throw APIRequestConfigurationValidationError.urlContainsUserInfo
        }
        guard url.query == nil else {
            throw APIRequestConfigurationValidationError.urlContainsQuery
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(HTTPMethod.self, forKey: .method)
        url = try container.decode(URL.self, forKey: .url)
        headers = try container.decode([RequestHeader].self, forKey: .headers)
        queryItems = try container.decode([RequestQueryItem].self, forKey: .queryItems)
        jsonBodyReference = try container.decodeIfPresent(UUID.self, forKey: .jsonBodyReference)
        refreshInterval = try container.decode(TimeInterval.self, forKey: .refreshInterval)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(url, forKey: .url)
        try container.encode(headers, forKey: .headers)
        try container.encode(queryItems, forKey: .queryItems)
        try container.encodeIfPresent(jsonBodyReference, forKey: .jsonBodyReference)
        try container.encode(refreshInterval, forKey: .refreshInterval)
    }

    private enum CodingKeys: String, CodingKey {
        case method
        case url
        case headers
        case queryItems
        case jsonBodyReference
        case refreshInterval
    }
}

/// Authentication metadata only. The referenced secret is owned by Keychain.
public enum AuthenticationConfiguration: Codable, Equatable, Sendable {
    case none
    case bearer(credentialReference: UUID)
    case apiKeyHeader(name: String, credentialReference: UUID)
    case apiKeyQuery(name: String, credentialReference: UUID)
    case basic(credentialReference: UUID)
}

public struct APISource: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var request: APIRequestConfiguration
    public var authentication: AuthenticationConfiguration
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        request: APIRequestConfiguration,
        authentication: AuthenticationConfiguration = .none,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.request = request
        self.authentication = authentication
        self.isEnabled = isEnabled
    }
}

public struct DataPoint: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var jsonPointer: String
    public var label: String
    public var format: String
    public var fallback: String

    public init(
        id: UUID = UUID(),
        sourceID: UUID,
        jsonPointer: String,
        label: String,
        format: String = "{label} {value}",
        fallback: String = "—"
    ) {
        self.id = id
        self.sourceID = sourceID
        self.jsonPointer = jsonPointer
        self.label = label
        self.format = format
        self.fallback = fallback
    }
}

public struct MenuBarLayout: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var separator: String
    public var items: [DataPoint]

    public init(
        id: UUID = UUID(),
        separator: String = " · ",
        items: [DataPoint] = []
    ) {
        self.id = id
        self.separator = separator
        self.items = items
    }
}
