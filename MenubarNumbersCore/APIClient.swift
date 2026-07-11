import Foundation

public struct HTTPTransportResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public enum HTTPTransportError: Error, Equatable, Sendable {
    case responseTooLarge
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest, maximumResponseBytes: Int) async throws -> HTTPTransportResponse
}

public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest, maximumResponseBytes: Int) async throws -> HTTPTransportResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIClientError.network }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            throw HTTPTransportError.responseTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, 64 * 1024))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw HTTPTransportError.responseTooLarge }
            data.append(byte)
        }
        return HTTPTransportResponse(statusCode: response.statusCode, data: data)
    }
}

public enum APIClientError: Error, Equatable, LocalizedError, Sendable {
    case missingSecureValue
    case secureValueStoreFailure
    case invalidConfiguredJSONBody
    case invalidConfiguration
    case network
    case responseTooLarge
    case httpStatus(Int)
    case invalidJSONResponse

    public var errorDescription: String? {
        switch self {
        case .missingSecureValue: return "A required secure value is unavailable."
        case .secureValueStoreFailure: return "The secure value store could not be accessed."
        case .invalidConfiguredJSONBody: return "The configured JSON body is invalid."
        case .invalidConfiguration: return "The API request configuration is invalid."
        case .network: return "The API request could not be completed."
        case .responseTooLarge: return "The API response exceeds the 2 MiB size limit."
        case let .httpStatus(status): return "The API returned HTTP status \(status)."
        case .invalidJSONResponse: return "The API response is not valid JSON."
        }
    }
}

public actor APIClient {
    public static let maximumResponseBytes = 2 * 1024 * 1024

    private let transport: any HTTPTransport
    private let secureValueStore: any SecureValueStore

    public init(transport: any HTTPTransport = URLSessionHTTPTransport(), secureValueStore: any SecureValueStore) {
        self.transport = transport
        self.secureValueStore = secureValueStore
    }

    public func fetch(source: APISource) async throws -> JSONValue {
        let request = try buildRequest(source: source)
        let response: HTTPTransportResponse
        do {
            response = try await transport.data(for: request, maximumResponseBytes: Self.maximumResponseBytes)
        } catch HTTPTransportError.responseTooLarge {
            throw APIClientError.responseTooLarge
        } catch let error as APIClientError {
            throw error
        } catch {
            throw APIClientError.network
        }
        guard response.data.count <= Self.maximumResponseBytes else {
            throw APIClientError.responseTooLarge
        }
        guard (200...299).contains(response.statusCode) else {
            throw APIClientError.httpStatus(response.statusCode)
        }
        do {
            return try JSONValue.parse(response.data)
        } catch {
            throw APIClientError.invalidJSONResponse
        }
    }

    public func buildRequest(source: APISource) throws -> URLRequest {
        do {
            try source.request.validate()
        } catch {
            throw APIClientError.invalidConfiguration
        }

        guard var components = URLComponents(url: source.request.url, resolvingAgainstBaseURL: false) else {
            throw APIClientError.invalidConfiguration
        }
        var queryItems: [URLQueryItem] = []
        for item in source.request.queryItems {
            queryItems.append(URLQueryItem(name: item.name, value: try secureValue(for: item.valueReference)))
        }

        var request = URLRequest(url: source.request.url)
        request.httpMethod = source.request.method.rawValue
        request.timeoutInterval = 15
        for header in source.request.headers {
            request.setValue(try secureValue(for: header.valueReference), forHTTPHeaderField: header.name)
        }

        switch source.authentication {
        case .none:
            break
        case let .bearer(credentialReference):
            request.setValue("Bearer \(try secureValue(for: credentialReference))", forHTTPHeaderField: "Authorization")
        case let .apiKeyHeader(name, credentialReference):
            request.setValue(try secureValue(for: credentialReference), forHTTPHeaderField: name)
        case let .apiKeyQuery(name, credentialReference):
            queryItems.append(URLQueryItem(name: name, value: try secureValue(for: credentialReference)))
        case let .basic(credentialReference):
            let credential = try secureValue(for: credentialReference)
            let encoded = Data(credential.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw APIClientError.invalidConfiguration }
        request.url = url

        if let bodyReference = source.request.jsonBodyReference {
            let body = try secureValue(for: bodyReference)
            let data = Data(body.utf8)
            guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                throw APIClientError.invalidConfiguredJSONBody
            }
            request.httpBody = data
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    private func secureValue(for reference: UUID) throws -> String {
        do {
            return try secureValueStore.value(for: reference)
        } catch let error as SecureValueStoreError {
            switch error {
            case .notFound: throw APIClientError.missingSecureValue
            case .keychainFailure: throw APIClientError.secureValueStoreFailure
            }
        } catch {
            throw APIClientError.secureValueStoreFailure
        }
    }
}
