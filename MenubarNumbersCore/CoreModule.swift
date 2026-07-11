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

public enum APIRequestFieldLocation: String, Codable, Equatable, Sendable {
    case header
    case queryItem
    case jsonBody
}

public enum APIRequestConfigurationValidationError: Error, Equatable, LocalizedError, Sendable {
    case urlContainsUserInfo
    case prohibitedField(name: String, location: APIRequestFieldLocation)
    case invalidJSONBody

    public var errorDescription: String? {
        switch self {
        case .urlContainsUserInfo:
            return "Request URLs cannot include user information. Store credentials in Keychain instead."
        case let .prohibitedField(name, location):
            return "\(location.rawValue) field '\(name)' may contain credentials. Store credentials in Keychain instead."
        case .invalidJSONBody:
            return "The static JSON request body is invalid."
        }
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

    /// Rejects request fields that could persist credentials outside Keychain.
    public func validate() throws {
        guard url.user == nil, url.password == nil else {
            throw APIRequestConfigurationValidationError.urlContainsUserInfo
        }

        if let name = headers.keys.first(where: Self.isCredentialBearingFieldName) {
            throw APIRequestConfigurationValidationError.prohibitedField(name: name, location: .header)
        }

        if let name = queryItems.map(\.name).first(where: Self.isCredentialBearingFieldName) {
            throw APIRequestConfigurationValidationError.prohibitedField(name: name, location: .queryItem)
        }

        try validateJSONBody()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(HTTPMethod.self, forKey: .method)
        url = try container.decode(URL.self, forKey: .url)
        headers = try container.decode([String: String].self, forKey: .headers)
        queryItems = try container.decode([APIRequestQueryItem].self, forKey: .queryItems)
        jsonBody = try container.decodeIfPresent(String.self, forKey: .jsonBody)
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
        try container.encodeIfPresent(jsonBody, forKey: .jsonBody)
        try container.encode(refreshInterval, forKey: .refreshInterval)
    }

    private func validateJSONBody() throws {
        guard let jsonBody else { return }

        do {
            let jsonObject = try JSONSerialization.jsonObject(
                with: Data(jsonBody.utf8),
                options: [.fragmentsAllowed]
            )
            if let name = Self.credentialBearingKey(in: jsonObject) {
                throw APIRequestConfigurationValidationError.prohibitedField(name: name, location: .jsonBody)
            }
        } catch let error as APIRequestConfigurationValidationError {
            throw error
        } catch {
            throw APIRequestConfigurationValidationError.invalidJSONBody
        }
    }

    private static func credentialBearingKey(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, nestedValue) in dictionary {
                if isCredentialBearingFieldName(key) {
                    return key
                }
                if let nestedKey = credentialBearingKey(in: nestedValue) {
                    return nestedKey
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                if let nestedKey = credentialBearingKey(in: item) {
                    return nestedKey
                }
            }
        }

        return nil
    }

    private static func isCredentialBearingFieldName(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if normalized == "auth" {
            return true
        }

        let prohibitedFragments = [
            "authorization",
            "authentication",
            "apikey",
            "token",
            "secret",
            "password",
            "credential",
            "bearer",
            "privatekey",
            "accesskey"
        ]
        return prohibitedFragments.contains { normalized.contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case method
        case url
        case headers
        case queryItems
        case jsonBody
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
