import Foundation

public enum MenubarNumbersCore {}

public enum HTTPMethod: String, Codable, Sendable {
    case get = "GET"
    case post = "POST"
}

public struct APIRequestQueryItem: Codable, Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Persisted request details. Authentication values remain in Keychain and are
/// deliberately represented only by `AuthenticationConfiguration` references.
public struct APIRequestConfiguration: Codable, Equatable, Sendable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var queryItems: [APIRequestQueryItem]
    public var jsonBody: String?
    public var refreshInterval: TimeInterval

    public init(
        method: HTTPMethod = .get,
        url: URL,
        headers: [String: String] = [:],
        queryItems: [APIRequestQueryItem] = [],
        jsonBody: String? = nil,
        refreshInterval: TimeInterval = 60
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.queryItems = queryItems
        self.jsonBody = jsonBody
        self.refreshInterval = refreshInterval
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
