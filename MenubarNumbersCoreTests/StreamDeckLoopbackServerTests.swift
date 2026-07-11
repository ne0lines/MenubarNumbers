import XCTest
@testable import MenubarNumbersCore

final class StreamDeckLoopbackServerTests: XCTestCase {
    func testWritesPrivateDiscoveryAndServesAuthenticatedLoopbackRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let discoveryURL = directory.appendingPathComponent("streamdeck-bridge.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = StreamDeckSourceSummary(
            id: UUID(), name: "Weather", isEnabled: true,
            hasResponse: false, lastSuccess: nil, error: nil
        )
        let server = StreamDeckLoopbackServer(
            discoveryURL: discoveryURL,
            backend: LoopbackBackendStub(sources: [source])
        )

        let discovery = try await server.start()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(discovery.port)/v1/sources")!)
        request.setValue("Bearer \(discovery.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let attributes = try FileManager.default.attributesOfItem(atPath: discoveryURL.path)
        server.stop()

        XCTAssertEqual(discovery.version, 1)
        XCTAssertGreaterThan(discovery.port, 0)
        XCTAssertEqual(discovery.token.count, 64)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try isoDecoder().decode([StreamDeckSourceSummary].self, from: data), [source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: discoveryURL.path))
    }

    func testRejectsUnauthenticatedRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let discoveryURL = directory.appendingPathComponent("streamdeck-bridge.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = StreamDeckLoopbackServer(discoveryURL: discoveryURL, backend: LoopbackBackendStub())
        let discovery = try await server.start()

        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(discovery.port)/v1/sources")!
        )
        server.stop()

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
    }

    private func isoDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private actor LoopbackBackendStub: StreamDeckBridgeBackend {
    let sourceValues: [StreamDeckSourceSummary]

    init(sources: [StreamDeckSourceSummary] = []) {
        sourceValues = sources
    }

    func sources() async -> [StreamDeckSourceSummary] { sourceValues }
    func fields(sourceID: UUID, refresh: Bool) async -> [StreamDeckScalarField] { [] }
    func replaceSubscriptions(clientID: String, selections: Set<StreamDeckSelection>) async {}
    func snapshots(selections: Set<StreamDeckSelection>) async -> [StreamDeckSnapshot] { [] }
}
