import XCTest
@testable import MenubarNumbersCore

final class StreamDeckHistoryStoreTests: XCTestCase {
    func testHistoryRecordsOnlyNumericSparklineValuesAndKeepsSixty() {
        let sourceID = UUID()
        let selection = StreamDeckSelection(sourceID: sourceID, jsonPointer: "/count", displayMode: .sparkline)
        var store = StreamDeckHistoryStore(limit: 60)

        for value in 0..<65 {
            store.record(
                response: .object(["count": .number(Decimal(value))]),
                sourceID: sourceID,
                selections: [selection],
                timestamp: Date(timeIntervalSince1970: Double(value))
            )
        }

        XCTAssertEqual(store.samples(for: selection).count, 60)
        XCTAssertEqual(store.samples(for: selection).first?.value, 5)
        XCTAssertEqual(store.samples(for: selection).last?.value, 64)
    }

    func testHistoryIgnoresValueModeAndNonNumericValues() {
        let sourceID = UUID()
        let value = StreamDeckSelection(sourceID: sourceID, jsonPointer: "/count", displayMode: .value)
        let sparkline = StreamDeckSelection(sourceID: sourceID, jsonPointer: "/name", displayMode: .sparkline)
        var store = StreamDeckHistoryStore()

        store.record(
            response: .object(["count": .number(1), "name": .string("one")]),
            sourceID: sourceID,
            selections: [value, sparkline],
            timestamp: Date()
        )

        XCTAssertEqual(store.samples(for: value), [])
        XCTAssertEqual(store.samples(for: sparkline), [])
    }

    func testHistoryPersistsAndCorruptDataLoadsAsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceID = UUID()
        let selection = StreamDeckSelection(sourceID: sourceID, jsonPointer: "/count", displayMode: .sparkline)
        var store = StreamDeckHistoryStore()
        store.record(
            response: .object(["count": .number(7)]),
            sourceID: sourceID,
            selections: [selection],
            timestamp: Date(timeIntervalSince1970: 10)
        )

        try store.save(to: url)
        XCTAssertEqual(StreamDeckHistoryStore.load(from: url).samples(for: selection).map(\.value), [7])

        try Data("not json".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(StreamDeckHistoryStore.load(from: url).samples(for: selection), [])
    }

    func testPrunesOnlyInactiveHistoriesOlderThanSevenDays() {
        let sourceID = UUID()
        let old = StreamDeckSelection(sourceID: sourceID, jsonPointer: "/old", displayMode: .sparkline)
        let recent = StreamDeckSelection(sourceID: sourceID, jsonPointer: "/recent", displayMode: .sparkline)
        var store = StreamDeckHistoryStore()
        store.markReferenced([old], at: Date(timeIntervalSince1970: 0))
        store.markReferenced([recent], at: Date(timeIntervalSince1970: 600_000))

        store.prune(inactiveBefore: Date(timeIntervalSince1970: 300_000))

        XCTAssertFalse(store.containsHistory(for: old))
        XCTAssertTrue(store.containsHistory(for: recent))
    }

    func testRemovingASourceDeletesItsHistoriesOnly() {
        let removedID = UUID()
        let keptID = UUID()
        let removed = StreamDeckSelection(sourceID: removedID, jsonPointer: "/count", displayMode: .sparkline)
        let kept = StreamDeckSelection(sourceID: keptID, jsonPointer: "/count", displayMode: .sparkline)
        var store = StreamDeckHistoryStore()
        store.markReferenced([removed, kept], at: Date())

        store.remove(sourceID: removedID)

        XCTAssertFalse(store.containsHistory(for: removed))
        XCTAssertTrue(store.containsHistory(for: kept))
    }
}
