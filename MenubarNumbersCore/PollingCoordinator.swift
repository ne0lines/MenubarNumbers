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

    private let refresh: Refresh
    private let sleep: Sleeper
    private var registrations: [UUID: Registration] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var inFlightSourceIDs: Set<UUID> = []
    private var pendingImmediateRefresh: Set<UUID> = []

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

        for (sourceID, registration) in registrations {
            guard let replacement = desired[sourceID], replacement == registration.source else {
                cancel(sourceID)
                continue
            }
        }

        for source in desired.values where registrations[source.id] == nil {
            start(source)
        }
    }

    /// Requests an immediate refresh of all currently active sources. Existing
    /// in-flight polling requests are reused instead of duplicated.
    public func refreshNow() async {
        let activeSources = registrations.values.map(\.source)
        await withTaskGroup(of: Void.self) { group in
            for source in activeSources {
                group.addTask { [weak self] in
                    await self?.refreshIfNeeded(source)
                }
            }
        }
    }

    /// Cancels all scheduled loops. In-flight requests are allowed to finish;
    /// callers retain their existing generation safeguards for stale results.
    public func stop() {
        for sourceID in Array(registrations.keys) {
            cancel(sourceID)
        }
    }

    private func start(_ source: APISource) {
        let token = UUID()
        registrations[source.id] = Registration(source: source, token: token)
        if inFlightSourceIDs.contains(source.id) {
            pendingImmediateRefresh.insert(source.id)
        }
        tasks[source.id] = Task { [weak self] in
            await self?.run(sourceID: source.id, token: token)
        }
    }

    private func cancel(_ sourceID: UUID) {
        registrations[sourceID] = nil
        pendingImmediateRefresh.remove(sourceID)
        tasks.removeValue(forKey: sourceID)?.cancel()
    }

    private func run(sourceID: UUID, token: UUID) async {
        defer {
            if registrations[sourceID]?.token == token {
                tasks[sourceID] = nil
            }
        }

        while !Task.isCancelled {
            guard let registration = registrations[sourceID], registration.token == token else { return }
            await refreshIfNeeded(registration.source, token: token)

            guard !Task.isCancelled,
                  let currentRegistration = registrations[sourceID],
                  currentRegistration.token == token else { return }
            await sleep(supportedInterval(for: currentRegistration.source.request.refreshInterval))
        }
    }

    private func refreshIfNeeded(_ source: APISource, token: UUID? = nil) async {
        guard let registration = registrations[source.id],
              registration.source == source,
              token == nil || token == registration.token,
              !inFlightSourceIDs.contains(source.id) else { return }

        inFlightSourceIDs.insert(source.id)
        await refresh(source)
        inFlightSourceIDs.remove(source.id)

        // A source can be changed while its prior request is completing. The
        // replacement loop skipped that first request to preserve no-overlap,
        // so start its configured request as soon as the old one ends.
        if pendingImmediateRefresh.remove(source.id) != nil,
           let replacement = registrations[source.id],
           replacement.source != source {
            await refreshIfNeeded(replacement.source, token: replacement.token)
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
