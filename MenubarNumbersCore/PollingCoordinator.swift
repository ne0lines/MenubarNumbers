import Foundation

/// Owns the recurring refresh task for each source currently represented in the
/// menu bar. Configuration is serialized by this actor so a source can never
/// have more than one polling loop or refresh request at a time.
public actor PollingCoordinator {
    public typealias Refresh = @Sendable (APISource) async -> Void
    public typealias Sleeper = @Sendable (TimeInterval) async -> Void

    private struct Registration: Sendable {
        let source: APISource
        let token: UUID
    }

    private enum InitialWork: Sendable {
        case refresh
        case waitThenSleep
        case waitThenRefresh
    }

    private let refresh: Refresh
    private let sleep: Sleeper
    private var registrations: [UUID: Registration] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var inFlightSourceIDs: Set<UUID> = []
    private var pendingImmediateRefresh: Set<UUID> = []
    private var refreshCompletionWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var cancelledRefreshWaiterIDs: Set<UUID> = []

    public init(refresh: @escaping Refresh) {
        self.refresh = refresh
        sleep = Self.defaultSleep
    }

    public init(refresh: @escaping Refresh, sleep: @escaping Sleeper) {
        self.refresh = refresh
        self.sleep = sleep
    }

    /// Replaces the complete polling registration. Only enabled sources which
    /// are referenced by the current menu-bar layout receive a loop.
    public func configure(sources: [APISource], activeSourceIDs: Set<UUID>) {
        var desired: [UUID: APISource] = [:]
        for source in sources where source.isEnabled && activeSourceIDs.contains(source.id) {
            // A malformed persisted configuration must not let one duplicate
            // ID crash polling; the last persisted source wins consistently.
            desired[source.id] = source
        }

        for sourceID in Array(registrations.keys) {
            guard let registration = registrations[sourceID] else { continue }
            guard let replacement = desired[sourceID], replacement == registration.source else {
                cancel(sourceID)
                continue
            }
        }

        for source in desired.values where registrations[source.id] == nil {
            let initialWork: InitialWork = inFlightSourceIDs.contains(source.id) ? .waitThenRefresh : .refresh
            start(source, initialWork: initialWork)
        }
    }

    /// Requests an immediate refresh of all currently active sources. The
    /// scheduled timer is restarted, so the next interval begins only after
    /// that refresh (or an already in-flight equivalent refresh) completes.
    public func refreshNow() async {
        let activeSources = registrations.values.map(\.source)
        for source in activeSources {
            let requiresReplacementRefresh = pendingImmediateRefresh.contains(source.id)
            let initialWork: InitialWork
            if inFlightSourceIDs.contains(source.id) {
                initialWork = requiresReplacementRefresh ? .waitThenRefresh : .waitThenSleep
            } else {
                initialWork = .refresh
            }
            cancel(source.id)
            start(source, initialWork: initialWork)
        }
    }

    /// Cancels all scheduled loops. In-flight requests are allowed to finish;
    /// callers retain their existing generation safeguards for stale results.
    public func stop() {
        for sourceID in Array(registrations.keys) {
            cancel(sourceID)
        }
    }

    func pendingRefreshWaiterCount() -> Int {
        refreshCompletionWaiters.values.reduce(0) { $0 + $1.count }
    }

    private func start(_ source: APISource, initialWork: InitialWork) {
        let token = UUID()
        registrations[source.id] = Registration(source: source, token: token)
        if case .waitThenRefresh = initialWork {
            pendingImmediateRefresh.insert(source.id)
        }
        tasks[source.id] = Task { [weak self] in
            await self?.run(sourceID: source.id, token: token, initialWork: initialWork)
        }
    }

    private func cancel(_ sourceID: UUID) {
        registrations[sourceID] = nil
        pendingImmediateRefresh.remove(sourceID)
        tasks.removeValue(forKey: sourceID)?.cancel()
    }

    private func run(sourceID: UUID, token: UUID, initialWork: InitialWork) async {
        defer {
            if registrations[sourceID]?.token == token {
                tasks[sourceID] = nil
            }
        }

        guard let initialRegistration = registrations[sourceID], initialRegistration.token == token else { return }
        switch initialWork {
        case .refresh:
            if !(await refreshIfNeeded(initialRegistration.source, token: token)) {
                await waitForRefreshCompletion(sourceID)
            }
        case .waitThenSleep:
            await waitForRefreshCompletion(sourceID)
        case .waitThenRefresh:
            await waitForRefreshCompletion(sourceID)
            guard registrations[sourceID]?.token == token,
                  pendingImmediateRefresh.remove(sourceID) != nil else { return }
            _ = await refreshIfNeeded(initialRegistration.source, token: token)
        }

        while !Task.isCancelled {
            guard let currentRegistration = registrations[sourceID], currentRegistration.token == token else { return }
            await sleep(supportedInterval(for: currentRegistration.source.request.refreshInterval))

            guard !Task.isCancelled,
                  let registration = registrations[sourceID],
                  registration.token == token else { return }
            if !(await refreshIfNeeded(registration.source, token: token)) {
                await waitForRefreshCompletion(sourceID)
            }
        }
    }

    private func refreshIfNeeded(_ source: APISource, token: UUID? = nil) async -> Bool {
        guard let registration = registrations[source.id],
              registration.source == source,
              token == nil || token == registration.token,
              !inFlightSourceIDs.contains(source.id) else { return false }

        inFlightSourceIDs.insert(source.id)
        await refresh(source)
        inFlightSourceIDs.remove(source.id)
        let waiters = refreshCompletionWaiters.removeValue(forKey: source.id) ?? [:]
        waiters.values.forEach { $0.resume() }
        return true
    }

    private func waitForRefreshCompletion(_ sourceID: UUID) async {
        guard inFlightSourceIDs.contains(sourceID) else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledRefreshWaiterIDs.remove(waiterID) != nil || !inFlightSourceIDs.contains(sourceID) {
                    continuation.resume()
                } else {
                    refreshCompletionWaiters[sourceID, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelRefreshWaiter(waiterID, sourceID: sourceID) }
        }
    }

    private func cancelRefreshWaiter(_ waiterID: UUID, sourceID: UUID) {
        if let continuation = refreshCompletionWaiters[sourceID]?.removeValue(forKey: waiterID) {
            continuation.resume()
        } else if inFlightSourceIDs.contains(sourceID) {
            cancelledRefreshWaiterIDs.insert(waiterID)
        }
    }

    private func supportedInterval(for requested: TimeInterval) -> TimeInterval {
        switch requested {
        case 15, 30, 60, 300:
            return requested
        default:
            return 60
        }
    }

    private static func defaultSleep(_ interval: TimeInterval) async {
        let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
