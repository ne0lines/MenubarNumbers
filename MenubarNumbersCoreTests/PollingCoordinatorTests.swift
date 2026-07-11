import XCTest
@testable import MenubarNumbersCore

final class PollingCoordinatorTests: XCTestCase {
    func testStartsOnlyEnabledSourcesReferencedByTheLayout() async {
        let recorder = RefreshRecorder()
        let sleeper = BlockingSleeper()
        let coordinator = PollingCoordinator(
            refresh: { source in await recorder.record(source.id) },
            sleep: { interval in await sleeper.sleep(interval) }
        )
        let active = source(named: "Active")
        let disabled = source(named: "Disabled", enabled: false)
        let unused = source(named: "Unused")

        await coordinator.configure(sources: [active, disabled, unused], activeSourceIDs: [active.id])

        let refreshedIDs = await recorder.waitForCount(1)
        XCTAssertEqual(refreshedIDs, [active.id])
        await coordinator.stop()
        await sleeper.releaseAll()
    }

    func testFetchesImmediatelyThenWaitsForTheConfiguredInterval() async {
        let recorder = RefreshRecorder()
        let sleeper = BlockingSleeper()
        let coordinator = PollingCoordinator(
            refresh: { source in await recorder.record(source.id) },
            sleep: { interval in await sleeper.sleep(interval) }
        )
        let source = source(named: "Weather", interval: 15)

        await coordinator.configure(sources: [source], activeSourceIDs: [source.id])

        let initialIDs = await recorder.waitForCount(1)
        let initialIntervals = await sleeper.waitForIntervals(count: 1)
        XCTAssertEqual(initialIDs, [source.id])
        XCTAssertEqual(initialIntervals, [15])
        await sleeper.releaseOne()
        let refreshedIDs = await recorder.waitForCount(2)
        XCTAssertEqual(refreshedIDs, [source.id, source.id])

        await coordinator.stop()
        await sleeper.releaseAll()
    }

    func testReconfiguringAnActiveSourceCancelsItsOldLoopAndStartsTheNewConfigurationImmediately() async {
        let recorder = RefreshRecorder()
        let sleeper = BlockingSleeper()
        let coordinator = PollingCoordinator(
            refresh: { source in await recorder.record(source.id) },
            sleep: { interval in await sleeper.sleep(interval) }
        )
        let original = source(named: "Rates", interval: 15)
        let replacement = APISource(
            id: original.id,
            name: original.name,
            request: APIRequestConfiguration(url: URL(string: "https://api.example.com/rates-v2")!, refreshInterval: 30)
        )

        await coordinator.configure(sources: [original], activeSourceIDs: [original.id])
        _ = await recorder.waitForCount(1)
        _ = await sleeper.waitForIntervals(count: 1)

        await coordinator.configure(sources: [replacement], activeSourceIDs: [replacement.id])

        let refreshedIDs = await recorder.waitForCount(2)
        let intervals = await sleeper.waitForIntervals(count: 2)
        XCTAssertEqual(refreshedIDs, [original.id, original.id])
        XCTAssertEqual(intervals, [15, 30])
        await sleeper.releaseOne()
        await Task.yield()
        let IDsAfterOldSleeperWakes = await recorder.ids()
        XCTAssertEqual(IDsAfterOldSleeperWakes, [original.id, original.id])

        await coordinator.stop()
        await sleeper.releaseAll()
    }

    func testRemovingASourceFromTheActiveLayoutCancelsItsLoop() async {
        let recorder = RefreshRecorder()
        let sleeper = BlockingSleeper()
        let coordinator = PollingCoordinator(
            refresh: { source in await recorder.record(source.id) },
            sleep: { interval in await sleeper.sleep(interval) }
        )
        let source = source(named: "Usage")

        await coordinator.configure(sources: [source], activeSourceIDs: [source.id])
        _ = await recorder.waitForCount(1)
        _ = await sleeper.waitForIntervals(count: 1)

        await coordinator.configure(sources: [source], activeSourceIDs: [])
        await sleeper.releaseAll()
        await Task.yield()
        let refreshedIDs = await recorder.ids()
        XCTAssertEqual(refreshedIDs, [source.id])

        await coordinator.stop()
    }

    func testManualRefreshUpdatesEveryActiveSourceWithoutStartingDuplicateRequests() async {
        let refresher = BlockingRefresher()
        let sleeper = BlockingSleeper()
        let coordinator = PollingCoordinator(
            refresh: { source in await refresher.refresh(source.id) },
            sleep: { interval in await sleeper.sleep(interval) }
        )
        let first = source(named: "First")
        let second = source(named: "Second")

        await coordinator.configure(sources: [first, second], activeSourceIDs: [first.id, second.id])
        let initiallyRefreshed = await refresher.waitForCount(2)
        XCTAssertEqual(Set(initiallyRefreshed), Set([first.id, second.id]))

        // Both loop requests are already in flight, so manual refresh must
        // share them rather than issue duplicate requests for either source.
        await coordinator.refreshNow()
        let manuallyRefreshed = await refresher.ids()
        XCTAssertEqual(Set(manuallyRefreshed), Set([first.id, second.id]))

        await refresher.releaseAll()
        _ = await sleeper.waitForIntervals(count: 2)
        await coordinator.stop()
        await sleeper.releaseAll()
    }

    func testManualRefreshCancelsTheOldSleepAndStartsANewFullIntervalAfterRefreshing() async {
        let recorder = RefreshRecorder()
        let sleeper = BlockingSleeper()
        let coordinator = PollingCoordinator(
            refresh: { source in await recorder.record(source.id) },
            sleep: { interval in await sleeper.sleep(interval) }
        )
        let source = source(named: "Weather", interval: 60)

        await coordinator.configure(sources: [source], activeSourceIDs: [source.id])
        _ = await recorder.waitForCount(1)
        _ = await sleeper.waitForIntervals(count: 1)

        await coordinator.refreshNow()
        _ = await recorder.waitForCount(2)
        await yieldToPollingTasks()

        let intervals = await sleeper.recordedIntervals()
        XCTAssertEqual(intervals, [60, 60])

        await coordinator.stop()
        await sleeper.releaseAll()
    }

    func testReplacementWaitsForItsOwnRefreshBeforeStartingItsNewInterval() async {
        let refresher = BlockingRefresher()
        let sleeper = BlockingSleeper()
        let coordinator = PollingCoordinator(
            refresh: { source in await refresher.refresh(source.id) },
            sleep: { interval in await sleeper.sleep(interval) }
        )
        let original = source(named: "Rates", interval: 15)
        let replacement = APISource(
            id: original.id,
            name: original.name,
            request: APIRequestConfiguration(url: URL(string: "https://api.example.com/rates-v2")!, refreshInterval: 30)
        )

        await coordinator.configure(sources: [original], activeSourceIDs: [original.id])
        _ = await refresher.waitForCount(1)

        await coordinator.configure(sources: [replacement], activeSourceIDs: [replacement.id])
        await yieldToPollingTasks()
        let intervalsBeforeOriginalCompletes = await sleeper.recordedIntervals()
        XCTAssertEqual(intervalsBeforeOriginalCompletes, [])

        await refresher.releaseOne()
        _ = await refresher.waitForCount(2)
        let intervalsBeforeReplacementCompletes = await sleeper.recordedIntervals()
        XCTAssertEqual(intervalsBeforeReplacementCompletes, [])

        await refresher.releaseOne()
        let intervals = await sleeper.waitForIntervals(count: 1)
        XCTAssertEqual(intervals, [30])

        await coordinator.stop()
        await sleeper.releaseAll()
    }
}

private func source(named name: String, enabled: Bool = true, interval: TimeInterval = 60) -> APISource {
    APISource(
        name: name,
        request: APIRequestConfiguration(url: URL(string: "https://api.example.com/\(name)")!, refreshInterval: interval),
        isEnabled: enabled
    )
}

private actor RefreshRecorder {
    private var recordedIDs: [UUID] = []

    func record(_ sourceID: UUID) {
        recordedIDs.append(sourceID)
    }

    func ids() -> [UUID] { recordedIDs }

    func waitForCount(_ count: Int) async -> [UUID] {
        while recordedIDs.count < count {
            await Task.yield()
        }
        return recordedIDs
    }
}

private actor BlockingRefresher {
    private var recordedIDs: [UUID] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func refresh(_ sourceID: UUID) async {
        recordedIDs.append(sourceID)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func ids() -> [UUID] { recordedIDs }

    func waitForCount(_ count: Int) async -> [UUID] {
        while recordedIDs.count < count {
            await Task.yield()
        }
        return recordedIDs
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor BlockingSleeper {
    private var intervals: [TimeInterval] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ interval: TimeInterval) async {
        intervals.append(interval)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForIntervals(count: Int) async -> [TimeInterval] {
        while intervals.count < count {
            await Task.yield()
        }
        return intervals
    }

    func recordedIntervals() -> [TimeInterval] { intervals }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func yieldToPollingTasks() async {
    for _ in 0 ..< 10 {
        await Task.yield()
    }
}
