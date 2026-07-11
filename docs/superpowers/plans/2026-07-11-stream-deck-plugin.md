# Stream Deck Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS Stream Deck plugin that displays any scalar value already fetched by MenubarNumbers, with an optional persisted sparkline for numeric values.

**Architecture:** MenubarNumbers owns API credentials, polling, scalar catalogues, and history, and exposes only sanitized data through a bearer-authenticated HTTP server bound to `127.0.0.1`. A TypeScript Stream Deck plugin discovers that server through a user-only Application Support file, batches all visible key subscriptions, and renders value or sparkline SVG images.

**Tech Stack:** Swift 6, SwiftUI, Network.framework, XCTest, TypeScript, Node.js 24, `@elgato/streamdeck` 2.1.0, Rollup, Vitest, Stream Deck 7.1 SDK/CLI.

---

## File map

Swift core files:

- `MenubarNumbersCore/StreamDeckBridgeModels.swift`: sanitized Codable bridge DTOs and JSON scalar catalogue builder.
- `MenubarNumbersCore/StreamDeckSubscriptionRegistry.swift`: leased active-selection union and expiry.
- `MenubarNumbersCore/StreamDeckHistoryStore.swift`: bounded numeric sampling plus atomic persistence.
- `MenubarNumbersCore/StreamDeckBridgeRouter.swift`: authenticated route parsing and response encoding.
- `MenubarNumbersCore/StreamDeckLoopbackServer.swift`: Network.framework HTTP transport and discovery-file lifecycle.

Swift app files:

- `MenubarNumbers/StreamDeckBridgeController.swift`: adapts bridge routes to `AppState` on the main actor.
- `MenubarNumbers/AppState.swift`: Stream Deck subscriptions, source union, catalogues, snapshots, and history recording.
- `MenubarNumbers/MenubarNumbersApp.swift`: bridge start/stop lifecycle.
- `MenubarNumbers.xcodeproj/project.pbxproj`: regenerated with XcodeGen whenever Swift files are added.

Swift test files:

- `MenubarNumbersCoreTests/StreamDeckBridgeModelsTests.swift`
- `MenubarNumbersCoreTests/StreamDeckSubscriptionRegistryTests.swift`
- `MenubarNumbersCoreTests/StreamDeckHistoryStoreTests.swift`
- `MenubarNumbersCoreTests/StreamDeckBridgeRouterTests.swift`
- `MenubarNumbersCoreTests/StreamDeckLoopbackServerTests.swift`

Plugin files:

- `streamdeck/package.json`, `package-lock.json`, `tsconfig.json`, `rollup.config.mjs`: deterministic Node build.
- `streamdeck/com.davidhermansson.menubarnumbers.sdPlugin/manifest.json`: one keypad action named API Data.
- `streamdeck/com.davidhermansson.menubarnumbers.sdPlugin/imgs/*.svg`: plugin/action icons.
- `streamdeck/com.davidhermansson.menubarnumbers.sdPlugin/ui/property-inspector.html`: local Property Inspector markup.
- `streamdeck/com.davidhermansson.menubarnumbers.sdPlugin/ui/property-inspector.js`: WebSocket registration, catalogue loading, filtering, and settings writes.
- `streamdeck/src/contracts.ts`: TypeScript mirror of the sanitized bridge schema.
- `streamdeck/src/bridge-client.ts`: discovery-file and authenticated HTTP client.
- `streamdeck/src/render.ts`: escaped, scalable value and sparkline SVG.
- `streamdeck/src/runtime.ts`: active-action batching, cache, heartbeat, and update loop.
- `streamdeck/src/actions/api-data.ts`: Stream Deck SDK adapter.
- `streamdeck/src/property-inspector.ts`: locally bundled Property Inspector behavior and pure filter/settings helpers.
- `streamdeck/src/plugin.ts`: logging, action registration, and SDK connection.
- `streamdeck/test/*.test.ts`: Vitest coverage for client, rendering, runtime, and settings.

Release/docs files:

- `.gitignore`: Node and plugin build outputs.
- `.github/workflows/release.yml`: Node 24 plugin test/build/validation/package and release attachment.
- `README.md`: requirements, installation, configuration, and local development.

### Task 1: Sanitized bridge models and scalar catalogue

**Files:**
- Create: `MenubarNumbersCore/StreamDeckBridgeModels.swift`
- Create: `MenubarNumbersCoreTests/StreamDeckBridgeModelsTests.swift`

- [ ] **Step 1: Write the failing scalar-catalogue tests**

```swift
import XCTest
@testable import MenubarNumbersCore

final class StreamDeckBridgeModelsTests: XCTestCase {
    func testCatalogueContainsOnlySortedScalarFieldsWithEscapedPointers() throws {
        let sourceID = UUID()
        let response = JSONValue.object([
            "nested/key": .object(["count~today": .number(12.5)]),
            "enabled": .bool(true),
            "object": .object([:])
        ])

        let fields = StreamDeckScalarCatalogue.fields(sourceID: sourceID, response: response)

        XCTAssertEqual(fields.map(\.jsonPointer), ["/enabled", "/nested~1key/count~0today"])
        XCTAssertEqual(fields[0].type, .boolean)
        XCTAssertEqual(fields[0].value, "true")
        XCTAssertNil(fields[0].numericValue)
        XCTAssertEqual(fields[1].type, .number)
        XCTAssertEqual(fields[1].numericValue, 12.5)
    }

    func testBridgeDTOEncodingCannotContainRequestConfiguration() throws {
        let source = StreamDeckSourceSummary(
            id: UUID(), name: "Weather", isEnabled: true,
            hasResponse: true, lastSuccess: Date(timeIntervalSince1970: 10), error: nil
        )
        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)

        XCTAssertFalse(encoded.contains("url"))
        XCTAssertFalse(encoded.contains("header"))
        XCTAssertFalse(encoded.contains("authentication"))
        XCTAssertFalse(encoded.contains("credential"))
    }
}
```

- [ ] **Step 2: Run the tests and confirm the new symbols are missing**

Run:

```bash
xcodegen generate
xcodebuild test -project MenubarNumbers.xcodeproj -scheme MenubarNumbers -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MenubarNumbersCoreTests/StreamDeckBridgeModelsTests
```

Expected: compilation fails because `StreamDeckScalarCatalogue` and bridge DTOs do not exist.

- [ ] **Step 3: Add the bridge contracts and catalogue builder**

Define these public Codable/Sendable types in `StreamDeckBridgeModels.swift`:

```swift
public enum StreamDeckScalarType: String, Codable, Sendable { case string, number, boolean, null }
public enum StreamDeckDisplayMode: String, Codable, Sendable { case value, sparkline }
public enum StreamDeckValueStatus: String, Codable, Sendable { case fresh, stale, missing }

public struct StreamDeckSelection: Codable, Hashable, Sendable {
    public let sourceID: UUID
    public let jsonPointer: String
    public let displayMode: StreamDeckDisplayMode
}

public struct StreamDeckSourceSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let isEnabled: Bool
    public let hasResponse: Bool
    public let lastSuccess: Date?
    public let error: String?
}

public struct StreamDeckScalarField: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let jsonPointer: String
    public let label: String
    public let type: StreamDeckScalarType
    public let value: String
    public let numericValue: Double?
}

public struct StreamDeckHistorySample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let value: Double
}

public struct StreamDeckSnapshot: Codable, Equatable, Sendable {
    public let selection: StreamDeckSelection
    public let type: StreamDeckScalarType?
    public let value: String?
    public let numericValue: Double?
    public let history: [StreamDeckHistorySample]
    public let status: StreamDeckValueStatus
    public let updatedAt: Date?
}
```

Implement `StreamDeckScalarCatalogue.fields(sourceID:response:)` by walking `response.tree`, excluding objects/arrays, preserving the tree's RFC 6901 pointers, and sorting by pointer. Convert numbers with `NSDecimalNumber(decimal:).doubleValue` while keeping the original decimal string in `value`.

- [ ] **Step 4: Run model tests**

Run the command from Step 2. Expected: `StreamDeckBridgeModelsTests` passes.

- [ ] **Step 5: Commit the contracts**

```bash
git add MenubarNumbersCore/StreamDeckBridgeModels.swift MenubarNumbersCoreTests/StreamDeckBridgeModelsTests.swift MenubarNumbers.xcodeproj/project.pbxproj
git commit -m "feat: add Stream Deck bridge contracts"
```

### Task 2: Leased subscriptions and persisted numeric history

**Files:**
- Create: `MenubarNumbersCore/StreamDeckSubscriptionRegistry.swift`
- Create: `MenubarNumbersCore/StreamDeckHistoryStore.swift`
- Create: `MenubarNumbersCoreTests/StreamDeckSubscriptionRegistryTests.swift`
- Create: `MenubarNumbersCoreTests/StreamDeckHistoryStoreTests.swift`

- [ ] **Step 1: Write failing registry and history tests**

```swift
func testRegistryUnionsClientsAndExpiresOldLeases() {
    let first = StreamDeckSelection(sourceID: UUID(), jsonPointer: "/a", displayMode: .value)
    let second = StreamDeckSelection(sourceID: UUID(), jsonPointer: "/b", displayMode: .sparkline)
    var registry = StreamDeckSubscriptionRegistry(leaseDuration: 30)
    let start = Date(timeIntervalSince1970: 100)

    registry.replace(clientID: "deck-a", selections: [first], now: start)
    registry.replace(clientID: "deck-b", selections: [second], now: start.addingTimeInterval(20))

    XCTAssertEqual(registry.activeSelections(now: start.addingTimeInterval(29)), [first, second])
    XCTAssertEqual(registry.activeSelections(now: start.addingTimeInterval(31)), [second])
}

func testHistoryRecordsOnlyNumericSparklineValuesAndKeepsSixty() throws {
    let sourceID = UUID()
    let selection = StreamDeckSelection(sourceID: sourceID, jsonPointer: "/count", displayMode: .sparkline)
    var store = StreamDeckHistoryStore(limit: 60)

    for value in 0..<65 {
        store.record(response: .object(["count": .number(Decimal(value))]),
                     sourceID: sourceID, selections: [selection],
                     timestamp: Date(timeIntervalSince1970: Double(value)))
    }

    XCTAssertEqual(store.samples(for: selection).count, 60)
    XCTAssertEqual(store.samples(for: selection).first?.value, 5)
    XCTAssertEqual(store.samples(for: selection).last?.value, 64)
}
```

Add persistence coverage that saves to a temporary URL, reloads the same samples, then writes invalid bytes and verifies `load(from:)` returns an empty store.

- [ ] **Step 2: Run focused tests and verify failure**

```bash
xcodegen generate
xcodebuild test -project MenubarNumbers.xcodeproj -scheme MenubarNumbers -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MenubarNumbersCoreTests/StreamDeckSubscriptionRegistryTests -only-testing:MenubarNumbersCoreTests/StreamDeckHistoryStoreTests
```

Expected: compilation fails for the two missing stores.

- [ ] **Step 3: Implement leased subscriptions**

Use a value-type registry so AppState can own it on the main actor:

```swift
public struct StreamDeckSubscriptionRegistry: Sendable {
    private struct Lease: Sendable { let selections: Set<StreamDeckSelection>; let expiresAt: Date }
    private let leaseDuration: TimeInterval
    private var leases: [String: Lease] = [:]

    public init(leaseDuration: TimeInterval = 30) { self.leaseDuration = leaseDuration }

    public mutating func replace(clientID: String, selections: Set<StreamDeckSelection>, now: Date) {
        leases[clientID] = Lease(selections: selections, expiresAt: now.addingTimeInterval(leaseDuration))
    }

    public mutating func activeSelections(now: Date) -> Set<StreamDeckSelection> {
        leases = leases.filter { $0.value.expiresAt > now }
        return leases.values.reduce(into: []) { $0.formUnion($1.selections) }
    }
}
```

- [ ] **Step 4: Implement bounded history and atomic persistence**

Key histories by a private Codable `sourceID + jsonPointer` key; display mode is not part of the key. `record` must filter to `.sparkline`, use `JSONValue.value(at:)`, accept only `.number`, append one timestamped sample, and retain `suffix(limit)`. `save(to:)` must create the parent directory and use `Data.write(options: .atomic)`. `load(from:)` returns an empty store for missing or undecodable data.

Track each key's `lastReferencedAt`. Add `prune(inactiveBefore:)` and remove only keys whose last reference is older than seven days, giving inactive keys a conservative recovery window while bounding disk growth.

- [ ] **Step 5: Run focused tests**

Run the command from Step 2. Expected: both suites pass.

- [ ] **Step 6: Commit subscription and history storage**

```bash
git add MenubarNumbersCore/StreamDeckSubscriptionRegistry.swift MenubarNumbersCore/StreamDeckHistoryStore.swift MenubarNumbersCoreTests/StreamDeckSubscriptionRegistryTests.swift MenubarNumbersCoreTests/StreamDeckHistoryStoreTests.swift MenubarNumbers.xcodeproj/project.pbxproj
git commit -m "feat: persist Stream Deck sparkline history"
```

### Task 3: Authenticated bridge router

**Files:**
- Create: `MenubarNumbersCore/StreamDeckBridgeRouter.swift`
- Create: `MenubarNumbersCoreTests/StreamDeckBridgeRouterTests.swift`

- [ ] **Step 1: Write failing route tests**

Create a `BridgeBackendStub` implementing the backend protocol and assert:

```swift
func testRejectsMissingBearerToken() async {
    let router = StreamDeckBridgeRouter(token: "secret", backend: BridgeBackendStub())
    let response = await router.route(.init(method: "GET", path: "/v1/sources", headers: [:], body: Data()))
    XCTAssertEqual(response.statusCode, 401)
}

func testRoutesAuthenticatedSourceList() async throws {
    let source = StreamDeckSourceSummary(id: UUID(), name: "Weather", isEnabled: true,
                                         hasResponse: false, lastSuccess: nil, error: nil)
    let router = StreamDeckBridgeRouter(token: "secret", backend: BridgeBackendStub(sources: [source]))
    let response = await router.route(.init(method: "GET", path: "/v1/sources",
        headers: ["authorization": "Bearer secret"], body: Data()))
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(try JSONDecoder().decode([StreamDeckSourceSummary].self, from: response.body), [source])
}
```

Also cover malformed JSON `400`, unknown route `404`, `POST /v1/fields`, `PUT /v1/subscriptions`, and `POST /v1/snapshots`.

- [ ] **Step 2: Run router tests and verify failure**

```bash
xcodegen generate
xcodebuild test -project MenubarNumbers.xcodeproj -scheme MenubarNumbers -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MenubarNumbersCoreTests/StreamDeckBridgeRouterTests
```

Expected: compilation fails for the router symbols.

- [ ] **Step 3: Define the backend boundary and exact routes**

```swift
public protocol StreamDeckBridgeBackend: Sendable {
    func sources() async -> [StreamDeckSourceSummary]
    func fields(sourceID: UUID, refresh: Bool) async -> [StreamDeckScalarField]
    func replaceSubscriptions(clientID: String, selections: Set<StreamDeckSelection>) async
    func snapshots(selections: Set<StreamDeckSelection>) async -> [StreamDeckSnapshot]
}
```

Use Codable bodies:

- `POST /v1/fields`: `{ "sourceID": UUID, "refresh": Bool }`
- `PUT /v1/subscriptions`: `{ "clientID": String, "selections": [...] }`
- `POST /v1/snapshots`: `{ "selections": [...] }`

Normalize header names to lowercase. Require exact `Authorization: Bearer <token>`. Encode all successful responses as JSON with ISO-8601 dates and `Content-Type: application/json`. Return JSON error bodies with only a stable `code`, never an underlying error description.

- [ ] **Step 4: Run router tests**

Run the command from Step 2. Expected: all router tests pass.

- [ ] **Step 5: Commit the router**

```bash
git add MenubarNumbersCore/StreamDeckBridgeRouter.swift MenubarNumbersCoreTests/StreamDeckBridgeRouterTests.swift MenubarNumbers.xcodeproj/project.pbxproj
git commit -m "feat: route authenticated Stream Deck bridge requests"
```

### Task 4: Loopback HTTP server and discovery file

**Files:**
- Create: `MenubarNumbersCore/StreamDeckLoopbackServer.swift`
- Create: `MenubarNumbersCoreTests/StreamDeckLoopbackServerTests.swift`

- [ ] **Step 1: Write failing integration tests**

Start the server with a temporary discovery URL and a router stub, then use URLSession to verify an authenticated `GET /v1/sources` succeeds. Read the discovery JSON and assert `version == 1`, `port > 0`, and a non-empty token. Use `FileManager.attributesOfItem` to assert the POSIX permissions are `0o600`. Send the same request without the token and assert `401`.

- [ ] **Step 2: Run the loopback suite and verify failure**

```bash
xcodegen generate
xcodebuild test -project MenubarNumbers.xcodeproj -scheme MenubarNumbers -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MenubarNumbersCoreTests/StreamDeckLoopbackServerTests
```

Expected: compilation fails because `StreamDeckLoopbackServer` is missing.

- [ ] **Step 3: Implement discovery and HTTP transport**

Define:

```swift
public struct StreamDeckBridgeDiscovery: Codable, Equatable, Sendable {
    public let version: Int
    public let port: UInt16
    public let token: String
}

public actor StreamDeckLoopbackServer {
    public init(discoveryURL: URL, handler: @escaping @Sendable (StreamDeckHTTPRequest) async -> StreamDeckHTTPResponse)
    public func start() async throws -> StreamDeckBridgeDiscovery
    public func stop() async
}
```

Create `NWParameters.tcp`, set `requiredLocalEndpoint` to `.hostPort(host: "127.0.0.1", port: .any)`, and build the listener from those parameters so the socket cannot accept non-loopback traffic. Cap request headers at 32 KiB and bodies at 256 KiB, support one request per connection, honor `Content-Length`, and always return `Connection: close`. Generate 32 random bytes with `SecRandomCopyBytes`, encode as lowercase hex, write discovery JSON atomically, then set permissions to `0o600`. `stop()` cancels the listener and removes only its own discovery file.

- [ ] **Step 4: Run the integration tests**

Run the command from Step 2. Expected: loopback, authentication, and permission tests pass.

- [ ] **Step 5: Commit transport and discovery**

```bash
git add MenubarNumbersCore/StreamDeckLoopbackServer.swift MenubarNumbersCoreTests/StreamDeckLoopbackServerTests.swift MenubarNumbers.xcodeproj/project.pbxproj
git commit -m "feat: serve Stream Deck data on loopback"
```

### Task 5: Connect bridge subscriptions, polling, catalogues, and history to AppState

**Files:**
- Modify: `MenubarNumbers/AppState.swift:5-305`
- Create: `MenubarNumbers/StreamDeckBridgeController.swift`
- Modify: `MenubarNumbers/MenubarNumbersApp.swift:1-38`

- [ ] **Step 1: Add AppState bridge state and deterministic injection points**

Add injected `historyURL`, `now`, and bridge controller factory defaults to `AppState.init`. Add private properties for `StreamDeckSubscriptionRegistry`, `StreamDeckHistoryStore`, an expiry task, and the bridge controller. Keep all mutations on `@MainActor`.

- [ ] **Step 2: Implement the backend adapter**

`StreamDeckBridgeController` conforms to `StreamDeckBridgeBackend` and calls closures isolated to `MainActor`:

```swift
final class StreamDeckBridgeController: StreamDeckBridgeBackend, @unchecked Sendable {
    private weak var state: AppState?

    init(state: AppState) { self.state = state }

    func sources() async -> [StreamDeckSourceSummary] {
        await MainActor.run { state?.streamDeckSources() ?? [] }
    }

    func fields(sourceID: UUID, refresh: Bool) async -> [StreamDeckScalarField] {
        guard let state else { return [] }
        if refresh { await state.refreshForStreamDeck(sourceID: sourceID) }
        return await MainActor.run { state.streamDeckFields(sourceID: sourceID) }
    }
}
```

Implement the write and snapshot methods explicitly:

```swift
func replaceSubscriptions(clientID: String, selections: Set<StreamDeckSelection>) async {
    guard let state else { return }
    await state.replaceStreamDeckSubscriptions(clientID: clientID, selections: selections)
}

func snapshots(selections: Set<StreamDeckSelection>) async -> [StreamDeckSnapshot] {
    guard let state else { return [] }
    return await MainActor.run { state.streamDeckSnapshots(selections: selections) }
}
```

Do not mark `AppState` itself unchecked-Sendable.

- [ ] **Step 3: Union Stream Deck sources into polling**

In `rebuildPolling`, replace the current active ID calculation with:

```swift
let menuBarSourceIDs = Set(layout.items.map(\.sourceID))
let streamDeckSourceIDs = Set(activeStreamDeckSelections().map(\.sourceID))
let activeSourceIDs = menuBarSourceIDs.union(streamDeckSourceIDs)
```

Every subscription update renews the 30-second lease, rebuilds polling if the union changed, and schedules one expiry check after the lease deadline. The TypeScript plugin will renew every 10 seconds.

On subscription changes, mark selected histories referenced and prune histories last referenced more than seven days ago.

- [ ] **Step 4: Record and persist successful numeric samples**

After `latestResponses[source.id] = response`, pass only active sparkline selections for that source to `historyStore.record`. Persist the updated store atomically. Deleting a source removes its histories. API errors, missing pointers, and non-numeric values must not append samples.

- [ ] **Step 5: Produce source, field, and snapshot responses**

Implement main-actor methods that:

- Map `APISource` to sanitized `StreamDeckSourceSummary`.
- Flatten only the latest response for the requested source.
- Refresh an enabled source through the existing refresh gate.
- Resolve each requested pointer into value/type/numeric value.
- Return `.stale` when `errors[sourceID] != nil` but a last value exists, `.missing` for an absent/non-scalar pointer, otherwise `.fresh`.
- Attach history only for `.sparkline` selections.

- [ ] **Step 6: Start and stop the bridge with app lifecycle**

Add `.task { await state.startStreamDeckBridge() }` to the root `ContentView`. Add `applicationWillTerminate` forwarding through a closure installed by the app so `await state.stopStreamDeckBridge()` runs before exit. Use:

`~/Library/Application Support/MenubarNumbers/streamdeck-bridge.json` and `streamdeck-history.json`.

- [ ] **Step 7: Build and run the complete Swift suite**

```bash
xcodegen generate
xcodebuild test -project MenubarNumbers.xcodeproj -scheme MenubarNumbers -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: app builds and all old plus new tests pass.

- [ ] **Step 8: Commit app integration**

```bash
git add MenubarNumbers/AppState.swift MenubarNumbers/StreamDeckBridgeController.swift MenubarNumbers/MenubarNumbersApp.swift MenubarNumbers.xcodeproj/project.pbxproj
git commit -m "feat: connect Stream Deck bridge to app polling"
```

### Task 6: Scaffold the Stream Deck plugin

**Files:**
- Create: `streamdeck/package.json`
- Create: `streamdeck/package-lock.json`
- Create: `streamdeck/tsconfig.json`
- Create: `streamdeck/rollup.config.mjs`
- Create: `streamdeck/com.davidhermansson.menubarnumbers.sdPlugin/manifest.json`
- Create: `streamdeck/com.davidhermansson.menubarnumbers.sdPlugin/imgs/plugin.svg`
- Create: `streamdeck/com.davidhermansson.menubarnumbers.sdPlugin/imgs/action.svg`
- Create: `streamdeck/src/plugin.ts`
- Modify: `.gitignore`

- [ ] **Step 1: Add deterministic Node configuration**

Use Node 24 and these scripts/dependencies:

```json
{
  "name": "menubarnumbers-streamdeck",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "engines": { "node": ">=24" },
  "scripts": {
    "build": "rollup -c",
    "test": "vitest run",
    "validate": "streamdeck validate --no-update-check com.davidhermansson.menubarnumbers.sdPlugin",
    "pack": "npm run build && npm run validate && streamdeck pack --no-update-check --force --output dist com.davidhermansson.menubarnumbers.sdPlugin"
  },
  "dependencies": { "@elgato/streamdeck": "2.1.0" },
  "devDependencies": {
    "@elgato/cli": "1.7.4",
    "@rollup/plugin-typescript": "12.3.0",
    "rollup": "4.62.2",
    "tslib": "2.8.1",
    "typescript": "7.0.2",
    "vitest": "4.1.10"
  }
}
```

Configure TypeScript with `strict`, `noUncheckedIndexedAccess`, NodeNext module resolution, and ES2024 target. Configure Rollup with two entries: `src/plugin.ts` outputs `com.davidhermansson.menubarnumbers.sdPlugin/bin/plugin.js`, and `src/property-inspector.ts` outputs `com.davidhermansson.menubarnumbers.sdPlugin/ui/property-inspector.js` as a browser IIFE.

- [ ] **Step 2: Add a schema-valid manifest and local SVG icons**

Use plugin UUID `com.davidhermansson.menubarnumbers`, action UUID `com.davidhermansson.menubarnumbers.api-data`, macOS-only OS support, `Nodejs.Version: 24`, minimum Stream Deck version `7.1`, `PropertyInspectorPath: ui/property-inspector.html`, `UserTitleEnabled: false`, and one keypad state whose title is hidden because the plugin supplies SVG images.

- [ ] **Step 3: Install and build the empty entry point**

```bash
cd streamdeck
npm install
npm run build
```

Expected: lockfile is created and Rollup writes `bin/plugin.js`. If the active shell is below Node 24, switch with `nvm install 24 && nvm use 24` before `npm install`.

- [ ] **Step 4: Ignore generated outputs and commit scaffold**

Add `streamdeck/node_modules/`, `streamdeck/dist/`, and `streamdeck/**/*.log` to `.gitignore`; keep the compiled `sdPlugin/bin/plugin.js` ignored and generated by the build.

```bash
git add .gitignore streamdeck/package.json streamdeck/package-lock.json streamdeck/tsconfig.json streamdeck/rollup.config.mjs streamdeck/com.davidhermansson.menubarnumbers.sdPlugin streamdeck/src/plugin.ts
git commit -m "build: scaffold Stream Deck plugin"
```

### Task 7: TypeScript bridge client

**Files:**
- Create: `streamdeck/src/contracts.ts`
- Create: `streamdeck/src/bridge-client.ts`
- Create: `streamdeck/test/bridge-client.test.ts`

- [ ] **Step 1: Write failing bridge-client tests**

Inject discovery-file reading and `fetch`. Verify:

```typescript
it("discovers the port and authenticates requests", async () => {
  const fetcher = vi.fn().mockResolvedValue(new Response("[]", { status: 200 }));
  const client = new BridgeClient({
    readFile: async () => JSON.stringify({ version: 1, port: 43123, token: "secret" }),
    fetch: fetcher
  });

  await client.listSources();

  expect(fetcher).toHaveBeenCalledWith("http://127.0.0.1:43123/v1/sources",
    expect.objectContaining({ headers: { Authorization: "Bearer secret" } }));
});
```

Also verify invalid discovery JSON maps to `BridgeUnavailableError`, non-2xx bodies are not exposed in user state, and subscription/snapshot requests serialize the exact Swift field names.

- [ ] **Step 2: Run tests and verify failure**

```bash
cd streamdeck && npm test -- bridge-client.test.ts
```

Expected: test compilation fails because contracts and client are missing.

- [ ] **Step 3: Implement contracts and client**

Mirror the Swift DTOs exactly, using ISO date strings and UUID strings. Default discovery path:

```typescript
path.join(os.homedir(), "Library", "Application Support", "MenubarNumbers", "streamdeck-bridge.json")
```

On every request, reread discovery after a connection failure so an app restart and port rotation recover without plugin restart. Use a five-second `AbortSignal.timeout`, `Content-Type: application/json`, and the bearer header. Expose `listSources`, `fields`, `replaceSubscriptions`, and `snapshots` only.

- [ ] **Step 4: Run client tests and commit**

```bash
cd streamdeck && npm test -- bridge-client.test.ts
cd ..
git add streamdeck/src/contracts.ts streamdeck/src/bridge-client.ts streamdeck/test/bridge-client.test.ts
git commit -m "feat: connect plugin to MenubarNumbers bridge"
```

### Task 8: SVG value and sparkline rendering

**Files:**
- Create: `streamdeck/src/render.ts`
- Create: `streamdeck/test/render.test.ts`

- [ ] **Step 1: Write failing renderer tests**

Assert XML escaping, centered value-only output, min/max sparkline scaling, centered flat series, negative/decimal values, stale opacity, warning marker, and offline text:

```typescript
it("escapes values before placing them in SVG", () => {
  const svg = renderKey({ value: "<5 & rising>", mode: "value", status: "fresh", history: [] });
  expect(svg).toContain("&lt;5 &amp; rising&gt;");
  expect(svg).not.toContain("<5 & rising>");
});

it("centers a flat sparkline", () => {
  const svg = renderKey({ value: "5", mode: "sparkline", status: "fresh",
    history: [{ timestamp: "2026-07-11T10:00:00Z", value: 5 }, { timestamp: "2026-07-11T10:01:00Z", value: 5 }] });
  expect(svg).toContain('points="12,104 132,104"');
});
```

- [ ] **Step 2: Run renderer tests and verify failure**

```bash
cd streamdeck && npm test -- render.test.ts
```

- [ ] **Step 3: Implement a deterministic 144×144 SVG renderer**

Use a black background, white value text, and accent `#69D2FF` line. Fit value text using length thresholds, draw the sparkline in `x=12...132` and `y=72...124`, and return an SVG data URI suitable for `action.setImage`. Dim stale/offline content to `0.55`; draw a six-pixel amber status dot. Render `Offline` only when no cached value exists and `—` for missing pointers.

- [ ] **Step 4: Run renderer tests and commit**

```bash
cd streamdeck && npm test -- render.test.ts
cd ..
git add streamdeck/src/render.ts streamdeck/test/render.test.ts
git commit -m "feat: render Stream Deck values and sparklines"
```

### Task 9: Batched runtime and Stream Deck action adapter

**Files:**
- Create: `streamdeck/src/runtime.ts`
- Create: `streamdeck/src/actions/api-data.ts`
- Modify: `streamdeck/src/plugin.ts`
- Create: `streamdeck/test/runtime.test.ts`

- [ ] **Step 1: Write failing runtime tests**

Use fake action outputs and a fake client. Verify two keys produce one deduplicated subscription request and one snapshot request, settings changes replace the selection, disappearance removes it, heartbeat renews every ten seconds, snapshot results fan out to the correct key, and a bridge failure reuses cached SVG state with offline treatment.

- [ ] **Step 2: Run runtime tests and verify failure**

```bash
cd streamdeck && npm test -- runtime.test.ts
```

- [ ] **Step 3: Implement the pure runtime**

Define:

```typescript
export type ApiDataSettings = {
  sourceID?: string;
  jsonPointer?: string;
  displayMode?: "value" | "sparkline";
};

export type VisibleAction = {
  context: string;
  settings: ApiDataSettings;
  setImage(dataUri: string): Promise<void>;
};
```

`PluginRuntime` owns a random `clientID`, a `Map<string, VisibleAction>`, a one-second snapshot timer, and a ten-second subscription heartbeat. A cycle deduplicates selections, skips incomplete settings, calls one `snapshots` request, updates the cache, and renders each action. Catch bridge errors once per cycle, log a sanitized message, and render cached values as offline without discarding cache.

Inject a `RuntimeCache` with `load()` and `save()` methods. The SDK adapter implements it using Stream Deck global settings under a single `snapshotCache` key containing only selection keys, scalar values, types, timestamps, and numeric history. Load it before the first cycle and save after successful snapshots so cached offline rendering also survives a Stream Deck restart.

- [ ] **Step 4: Implement the SDK adapter**

Use `@action({ UUID: "com.davidhermansson.menubarnumbers.api-data" })` and extend `SingletonAction<ApiDataSettings>`. Forward `onWillAppear`, `onDidReceiveSettings`, and `onWillDisappear` to the shared runtime. Reject encoder contexts. Implement `onSendToPlugin` for Property Inspector catalogue messages by calling the shared bridge client and replying with `ev.action.sendToPropertyInspector`.

Register the action, start the runtime, enable file logging, and call `streamDeck.connect()` in `plugin.ts`.

- [ ] **Step 5: Run all plugin tests and build**

```bash
cd streamdeck
npm test
npm run build
```

Expected: all Vitest suites pass and Rollup emits the plugin binary.

- [ ] **Step 6: Commit runtime and action**

```bash
git add streamdeck/src/runtime.ts streamdeck/src/actions/api-data.ts streamdeck/src/plugin.ts streamdeck/test/runtime.test.ts
git commit -m "feat: update Stream Deck actions from batched snapshots"
```

### Task 10: Property Inspector source and field selection

**Files:**
- Create: `streamdeck/com.davidhermansson.menubarnumbers.sdPlugin/ui/property-inspector.html`
- Create: `streamdeck/src/property-inspector.ts`
- Create: `streamdeck/test/property-inspector.test.ts`

- [ ] **Step 1: Extract and test pure Property Inspector helpers**

Place exported helper functions in `src/property-inspector.ts` and test them through Vitest: field filtering matches label and JSON Pointer case-insensitively; changing source clears pointer and display mode; selecting a non-number forces `value`; number selection enables `sparkline`; settings payload contains only source ID, pointer, and display mode. Guard browser startup with `if (typeof window !== "undefined")` so the same module is testable under Node.

- [ ] **Step 2: Build local HTML without external dependencies**

Add native controls for source, search, field list, display mode, preview, pointer/type, updated time, status, and refresh. Style with Stream Deck's dark colors and system fonts. Keep all JavaScript local so the Property Inspector works without internet access.

- [ ] **Step 3: Implement WebSocket registration and messages**

Implement `window.connectElgatoStreamDeckSocket(port, uuid, registerEvent, info, actionInfo)`. Register with Stream Deck, request `getCatalog` from the plugin, receive `catalog`/`error`, and send `setSettings` after valid changes. Refresh sends `getCatalog` with `{ refresh: true, sourceID }`. Show `MenubarNumbers is offline` without clearing saved settings when the plugin reports an unavailable bridge.

- [ ] **Step 4: Test, build, and validate the plugin**

```bash
cd streamdeck
npm test -- property-inspector.test.ts
npm run build
npm run validate
```

Expected: helper tests pass and Stream Deck CLI reports the plugin valid.

- [ ] **Step 5: Commit Property Inspector**

```bash
git add streamdeck/com.davidhermansson.menubarnumbers.sdPlugin/ui/property-inspector.html streamdeck/src/property-inspector.ts streamdeck/test/property-inspector.test.ts
git commit -m "feat: configure API values in Property Inspector"
```

### Task 11: Documentation, release artifact, and end-to-end verification

**Files:**
- Modify: `README.md`
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Document requirements and user flow**

Document macOS 14+, Stream Deck 7.1+, Node 24 for development, installing the `.streamDeckPlugin`, keeping MenubarNumbers running, adding API Data to a key, selecting source/field/mode, persisted 60-sample history, offline behavior, and local bridge security. Add local commands for Swift tests and `cd streamdeck && npm ci && npm test && npm run pack`.

- [ ] **Step 2: Extend release CI**

Before release creation, add `actions/setup-node@v4` with `node-version: 24` and cache path `streamdeck/package-lock.json`; run `npm ci`, `npm test`, `npm run build`, `npm run validate`, and `npm run pack` in `streamdeck/`. Add `streamdeck/dist/*.streamDeckPlugin` and its SHA-256 file to the existing GitHub release files alongside the DMG.

- [ ] **Step 3: Run complete automated verification**

```bash
xcodebuild test -project MenubarNumbers.xcodeproj -scheme MenubarNumbers -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project MenubarNumbers.xcodeproj -scheme MenubarNumbers -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
cd streamdeck
npm ci
npm test
npm run build
npm run validate
npm run pack
cd ..
git diff --check
```

Expected: Swift suites and builds succeed, Vitest succeeds, CLI validation succeeds, and `streamdeck/dist/MenubarNumbers.streamDeckPlugin` exists.

- [ ] **Step 4: Perform manual Stream Deck verification**

Link the plugin with `cd streamdeck && npx streamdeck link com.davidhermansson.menubarnumbers.sdPlugin`, launch MenubarNumbers, and verify:

1. Two keys can select different fields from the same source.
2. One key can select a field from a source absent from the menu bar and receives polling updates.
3. Strings/booleans show value mode and numbers offer sparkline mode.
4. A flat series and changing series both render correctly.
5. API failure retains and dims the last value.
6. Quitting MenubarNumbers shows cached offline state; relaunch reconnects automatically.
7. Restarting both apps retains settings and numeric history.
8. Discovery and history files contain no API URL, header, query value, body, or credential.

- [ ] **Step 5: Commit docs and release integration**

```bash
git add README.md .github/workflows/release.yml
git commit -m "docs: add Stream Deck install and release flow"
```

- [ ] **Step 6: Request final code review**

Use `superpowers:requesting-code-review` against the complete branch diff. Address only verified actionable findings, rerun Step 3, and then use `superpowers:finishing-a-development-branch` for the user's chosen integration path.
