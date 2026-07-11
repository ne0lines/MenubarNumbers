import XCTest
@testable import MenubarNumbersCore

final class StreamDeckSubscriptionRegistryTests: XCTestCase {
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

    func testReplacingAClientReplacesRatherThanAccumulatesSelections() {
        let first = StreamDeckSelection(sourceID: UUID(), jsonPointer: "/a", displayMode: .value)
        let second = StreamDeckSelection(sourceID: UUID(), jsonPointer: "/b", displayMode: .sparkline)
        var registry = StreamDeckSubscriptionRegistry(leaseDuration: 30)
        let now = Date(timeIntervalSince1970: 100)

        registry.replace(clientID: "deck", selections: [first], now: now)
        registry.replace(clientID: "deck", selections: [second], now: now)

        XCTAssertEqual(registry.activeSelections(now: now), [second])
    }
}
