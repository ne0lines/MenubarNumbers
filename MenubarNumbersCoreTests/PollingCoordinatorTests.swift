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
        await shortDelay()
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
        await shortDelay()
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
        await shortDelay()

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
        await shortDelay()
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

    func testSharedRefreshGateCoalescesManualAndPollingRequestsForTheSameSource() async {
        let gate = SourceRefreshGate()
        let refresher = BlockingRefresher()
        let source = source(named: "Weather")

        let polling = Task {
            await gate.run(source: source) { source in
                await refresher.refresh(source.id)
            }
        }
        _ = await refresher.waitForCount(1)

        let manualRefresh = Task {
            await gate.run(source: source) { source in
                await refresher.refresh(source.id)
            }
        }
        let testConnection = Task {
            await gate.run(source: source) { source in
                await refresher.refresh(source.id)
            }
        }

        await shortDelay()
        let startedBeforeRelease = await refresher.ids()
        XCTAssertEqual(startedBeforeRelease, [source.id])
        await refresher.releaseOne()
        await polling.value
        await manualRefresh.value
        await testConnection.value
        let allStarted = await refresher.ids()
        XCTAssertEqual(allStarted, [source.id])
    }

    func testSharedRefreshGateRunsTheLatestReplacementAfterTheCurrentRequestFinishes() async {
        let gate = SourceRefreshGate()
        let recorder = SourceURLRecorder()
        let original = source(named: "Rates")
        let replacement = APISource(
            id: original.id,
            name: original.name,
            request: APIRequestConfiguration(url: URL(string: "https://api.example.com/rates-v2")!)
        )
        let firstStarted = AsyncGate()
        let releaseFirst = AsyncGate()

        let first = Task {
            await gate.run(source: original) { source in
                await recorder.record(source.request.url)
                await firstStarted.open()
                await releaseFirst.wait()
            }
        }
        await firstStarted.wait()
        let replacementTask = Task {
            await gate.run(source: replacement) { source in
                await recorder.record(source.request.url)
            }
        }

        await shortDelay()
        let urlsBeforeRelease = await recorder.urls()
        XCTAssertEqual(urlsBeforeRelease, [original.request.url])
        await releaseFirst.open()
        await first.value
        await replacementTask.value
        let urls = await recorder.urls()
        XCTAssertEqual(urls, [original.request.url, replacement.request.url])
    }

    func testCancellingRefreshGateWaiterRemovesItBeforeTheActiveRequestFinishes() async {
        let gate = SourceRefreshGate()
        let refresher = BlockingRefresher()
        let source = source(named: "Weather")

        let activeRequest = Task {
            await gate.run(source: source) { source in
                await refresher.refresh(source.id)
            }
        }
        _ = await refresher.waitForCount(1)

        let cancelledWaiter = Task {
            await gate.run(source: source) { source in
                await refresher.refresh(source.id)
            }
        }
        await shortDelay()
        let waiterCount = await gate.pendingWaiterCount()
        XCTAssertEqual(waiterCount, 1)

        cancelledWaiter.cancel()
        await shortDelay()
        let waiterCountAfterCancellation = await gate.pendingWaiterCount()
        XCTAssertEqual(waiterCountAfterCancellation, 0)
        await cancelledWaiter.value

        await refresher.releaseOne()
        await activeRequest.value
    }

    func testCancellingTheLastReplacementWaiterPreventsThatReplacementFromRunning() async {
        let gate = SourceRefreshGate()
        let recorder = SourceURLRecorder()
        let original = source(named: "Rates")
        let replacement = APISource(
            id: original.id,
            name: original.name,
            request: APIRequestConfiguration(url: URL(string: "https://api.example.com/rates-v2")!)
        )
        let firstStarted = AsyncGate()
        let releaseFirst = AsyncGate()

        let first = Task {
            await gate.run(source: original) { source in
                await recorder.record(source.request.url)
                await firstStarted.open()
                await releaseFirst.wait()
            }
        }
        await firstStarted.wait()
        let replacementWaiter = Task {
            await gate.run(source: replacement) { source in
                await recorder.record(source.request.url)
            }
        }
        await shortDelay()

        replacementWaiter.cancel()
        await replacementWaiter.value
        await releaseFirst.open()
        await first.value

        let urls = await recorder.urls()
        XCTAssertEqual(urls, [original.request.url])
    }

    func testCancellingReplacementLoopRemovesItsRefreshCompletionWaiter() async {
        let refresher = BlockingRefresher()
        let coordinator = PollingCoordinator(
            refresh: { source in await refresher.refresh(source.id) },
            sleep: { _ in }
        )
        let original = source(named: "Rates")
        let replacement = APISource(
            id: original.id,
            name: original.name,
            request: APIRequestConfiguration(url: URL(string: "https://api.example.com/rates-v2")!, refreshInterval: 30)
        )

        await coordinator.configure(sources: [original], activeSourceIDs: [original.id])
        _ = await refresher.waitForCount(1)
        await coordinator.configure(sources: [replacement], activeSourceIDs: [replacement.id])
        await shortDelay()
        let waiterCount = await coordinator.pendingRefreshWaiterCount()
        XCTAssertEqual(waiterCount, 1)

        await coordinator.configure(sources: [], activeSourceIDs: [])
        await shortDelay()
        let waiterCountAfterCancellation = await coordinator.pendingRefreshWaiterCount()
        XCTAssertEqual(waiterCountAfterCancellation, 0)

        await refresher.releaseAll()
        await coordinator.stop()
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while recordedIDs.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while recordedIDs.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while intervals.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
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

private actor SourceURLRecorder {
    private var recordedURLs: [URL] = []

    func record(_ url: URL) { recordedURLs.append(url) }
    func urls() -> [URL] { recordedURLs }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private func shortDelay() async {
    try? await Task.sleep(for: .milliseconds(10))
}
