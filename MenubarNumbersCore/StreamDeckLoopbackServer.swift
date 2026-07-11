import Foundation
@preconcurrency import Network
import Security

public struct StreamDeckBridgeDiscovery: Codable, Equatable, Sendable {
    public let version: Int
    public let port: UInt16
    public let token: String

    public init(version: Int = 1, port: UInt16, token: String) {
        self.version = version
        self.port = port
        self.token = token
    }
}

public enum StreamDeckLoopbackServerError: Error, LocalizedError, Sendable {
    case listenerFailed
    case unavailablePort
    case randomGenerationFailed

    public var errorDescription: String? {
        "The local Stream Deck bridge could not be started."
    }
}

public final class StreamDeckLoopbackServer: @unchecked Sendable {
    private static let maximumHeaderBytes = 32 * 1_024
    private static let maximumBodyBytes = 256 * 1_024

    private let discoveryURL: URL
    private let backend: any StreamDeckBridgeBackend
    private let queue = DispatchQueue(label: "com.davidhermansson.MenubarNumbers.streamdeck-bridge")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var discovery: StreamDeckBridgeDiscovery?
    private var router: StreamDeckBridgeRouter?

    public init(discoveryURL: URL, backend: any StreamDeckBridgeBackend) {
        self.discoveryURL = discoveryURL
        self.backend = backend
    }

    public func start() async throws -> StreamDeckBridgeDiscovery {
        let existing: StreamDeckBridgeDiscovery? = locked { self.discovery }
        if let existing { return existing }

        let token = try Self.generateToken()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        locked {
            self.listener = listener
            router = StreamDeckBridgeRouter(token: token, backend: backend)
        }
        let port: UInt16
        do {
            port = try await waitUntilReady(listener)
        } catch {
            stop()
            throw error
        }
        let discovery = StreamDeckBridgeDiscovery(port: port, token: token)
        do {
            try writeDiscovery(discovery)
        } catch {
            stop()
            throw error
        }
        locked { self.discovery = discovery }
        return discovery
    }

    private func waitUntilReady(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: StreamDeckLoopbackServerError.unavailablePort)
                        return
                    }
                    continuation.resume(returning: port.rawValue)
                case .failed, .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: StreamDeckLoopbackServerError.listenerFailed)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        let state = locked { () -> (NWListener?, [NWConnection], StreamDeckBridgeDiscovery?) in
            let value = (listener, Array(connections.values), discovery)
            listener = nil
            connections = [:]
            router = nil
            discovery = nil
            return value
        }
        state.0?.cancel()
        state.1.forEach { $0.cancel() }
        guard let ownedDiscovery = state.2,
              let data = try? Data(contentsOf: discoveryURL),
              let onDisk = try? JSONDecoder().decode(StreamDeckBridgeDiscovery.self, from: data),
              onDisk.token == ownedDiscovery.token else { return }
        try? FileManager.default.removeItem(at: discoveryURL)
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        locked { connections[id] = connection }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receive(connection: connection, id: id, buffer: Data())
            case .failed, .cancelled:
                self.removeConnection(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1_024) { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if error != nil {
                self.close(connection: connection, id: id)
                return
            }
            Task { await self.processOrReceiveMore(connection: connection, id: id, buffer: accumulated) }
        }
    }

    private func processOrReceiveMore(connection: NWConnection, id: UUID, buffer: Data) async {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: delimiter) else {
            if buffer.count > Self.maximumHeaderBytes {
                send(StreamDeckHTTPResponse(statusCode: 413), connection: connection, id: id)
            } else {
                receive(connection: connection, id: id, buffer: buffer)
            }
            return
        }
        guard headerRange.lowerBound <= Self.maximumHeaderBytes,
              let headerText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else {
            send(StreamDeckHTTPResponse(statusCode: 400), connection: connection, id: id)
            return
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            send(StreamDeckHTTPResponse(statusCode: 400), connection: connection, id: id)
            return
        }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3 else {
            send(StreamDeckHTTPResponse(statusCode: 400), connection: connection, id: id)
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard let bodyLength = Int(headers["content-length"] ?? "0"), bodyLength >= 0 else {
            send(StreamDeckHTTPResponse(statusCode: 400), connection: connection, id: id)
            return
        }
        guard bodyLength <= Self.maximumBodyBytes else {
            send(StreamDeckHTTPResponse(statusCode: 413), connection: connection, id: id)
            return
        }
        let bodyStart = headerRange.upperBound
        let availableBodyBytes = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard availableBodyBytes >= bodyLength else {
            receive(connection: connection, id: id, buffer: buffer)
            return
        }
        let bodyEnd = buffer.index(bodyStart, offsetBy: bodyLength)
        let request = StreamDeckHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: Data(buffer[bodyStart..<bodyEnd])
        )
        let activeRouter: StreamDeckBridgeRouter? = locked { self.router }
        guard let activeRouter else {
            send(StreamDeckHTTPResponse(statusCode: 500), connection: connection, id: id)
            return
        }
        send(await activeRouter.route(request), connection: connection, id: id)
    }

    private func send(_ response: StreamDeckHTTPResponse, connection: NWConnection, id: UUID) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        let statusText: String
        switch response.statusCode {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        default: statusText = "Internal Server Error"
        }
        var data = Data("HTTP/1.1 \(response.statusCode) \(statusText)\r\n".utf8)
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            data.append(Data("\(name): \(value)\r\n".utf8))
        }
        data.append(Data("\r\n".utf8))
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] _ in
            guard let self, let connection else { return }
            self.close(connection: connection, id: id)
        })
    }

    private func close(connection: NWConnection, id: UUID) {
        connection.cancel()
        removeConnection(id)
    }

    private func removeConnection(_ id: UUID) {
        locked { connections[id] = nil }
    }

    private func writeDiscovery(_ discovery: StreamDeckBridgeDiscovery) throws {
        try FileManager.default.createDirectory(
            at: discoveryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(discovery).write(to: discoveryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: discoveryURL.path)
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StreamDeckLoopbackServerError.randomGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
