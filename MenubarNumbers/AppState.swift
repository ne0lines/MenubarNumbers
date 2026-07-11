import Combine
import Foundation
import MenubarNumbersCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var sources: [APISource]
    @Published private(set) var layout: MenuBarLayout
    @Published var selectedSourceID: UUID?
    @Published private(set) var latestResponses: [UUID: JSONValue] = [:]
    @Published private(set) var lastSuccess: [UUID: Date] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var loadingSourceIDs: Set<UUID> = []
    @Published private(set) var secureCleanupStatus: String?

    private let defaults: UserDefaults
    private let secureStore: KeychainStore
    private let client: APIClient
    private let refreshGate = SourceRefreshGate()
    private let sourcesKey = "sources.v1"
    private let layoutKey = "menuBarLayout.v1"
    private let pendingSecureCleanupKey = "pendingSecureValueCleanup.v1"
    private let streamDeckHistoryURL: URL
    private let streamDeckDiscoveryURL: URL
    private let now: () -> Date
    private var pendingSecureCleanupReferences: Set<UUID>
    private var requestGenerations = SourceRequestGenerations()
    private var pollingConfigurationGeneration: UInt64 = 0
    private var streamDeckSubscriptions = StreamDeckSubscriptionRegistry()
    private var streamDeckSelections: Set<StreamDeckSelection> = []
    private var streamDeckHistory: StreamDeckHistoryStore
    private var streamDeckExpiryTask: Task<Void, Never>?
    private var streamDeckServer: StreamDeckLoopbackServer?
    private lazy var pollingCoordinator = PollingCoordinator { [weak self] source in
        await self?.refresh(source)
    }

    init(
        defaults: UserDefaults = .standard,
        secureStore: KeychainStore = KeychainStore(),
        applicationSupportDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let supportDirectory = applicationSupportDirectory ?? Self.defaultApplicationSupportDirectory()
        self.defaults = defaults
        self.secureStore = secureStore
        self.now = now
        streamDeckHistoryURL = supportDirectory.appendingPathComponent("streamdeck-history.json")
        streamDeckDiscoveryURL = supportDirectory.appendingPathComponent("streamdeck-bridge.json")
        streamDeckHistory = StreamDeckHistoryStore.load(from: streamDeckHistoryURL)
        client = APIClient(secureValueStore: secureStore)
        sources = Self.load([APISource].self, from: defaults, key: "sources.v1") ?? []
        layout = Self.load(MenuBarLayout.self, from: defaults, key: "menuBarLayout.v1") ?? MenuBarLayout()
        pendingSecureCleanupReferences = Set(
            (defaults.stringArray(forKey: "pendingSecureValueCleanup.v1") ?? []).compactMap(UUID.init(uuidString:))
        )
        selectedSourceID = sources.first?.id
        retrySecureValueCleanup()
        rebuildPolling()
    }

    var selectedSource: APISource? {
        sources.first { $0.id == selectedSourceID }
    }

    var menuBarText: String {
        let text = MenuBarTextRenderer.render(layout: layout, responses: latestResponses)
        return text.isEmpty ? "MenubarNumbers" : text
    }

    func addSource() {
        retrySecureValueCleanup()
        let source = APISource(
            name: "New API",
            request: APIRequestConfiguration(url: URL(string: "https://api.example.com")!)
        )
        sources.append(source)
        selectedSourceID = source.id
        try? persistConfiguration()
        rebuildPolling()
    }

    func deleteSelectedSource() {
        guard let source = selectedSource else { return }
        retrySecureValueCleanup()
        requestGenerations.invalidate(source.id)
        let originalSources = sources
        let originalLayout = layout
        let originalSelection = selectedSourceID
        queueSecureReferences(secureReferences(in: source))
        sources.removeAll { $0.id == source.id }
        layout.items.removeAll { $0.sourceID == source.id }
        latestResponses[source.id] = nil
        lastSuccess[source.id] = nil
        errors[source.id] = nil
        selectedSourceID = sources.first?.id
        do {
            try persistConfiguration()
            streamDeckHistory.remove(sourceID: source.id)
            persistStreamDeckHistory()
            retrySecureValueCleanup()
        } catch {
            sources = originalSources
            layout = originalLayout
            selectedSourceID = originalSelection
            removeQueuedSecureReferences(secureReferences(in: source))
            errors[source.id] = safeMessage(for: error)
        }
        rebuildPolling()
    }

    func draft(for source: APISource) -> SourceDraft {
        SourceDraft(source: source, secureStore: secureStore)
    }

    func saveAndTest(_ draft: SourceDraft) async {
        do {
            let source = try save(draft)
            await refresh(source)
        } catch {
            errors[draft.id] = safeMessage(for: error)
        }
    }

    func refreshSelected() async {
        guard let source = selectedSource else { return }
        await refresh(source)
    }

    func refreshAll() async {
        await pollingCoordinator.refreshNow()
    }

    func addDataPoint(sourceID: UUID, pointer: String, label: String) {
        guard !layout.items.contains(where: { $0.sourceID == sourceID && $0.jsonPointer == pointer }) else { return }
        layout.items.append(DataPoint(sourceID: sourceID, jsonPointer: pointer, label: label))
        try? persistConfiguration()
        rebuildPolling()
    }

    func removeDataPoint(_ point: DataPoint) {
        layout.items.removeAll { $0.id == point.id }
        try? persistConfiguration()
        rebuildPolling()
    }

    func moveDataPoint(_ point: DataPoint, by offset: Int) {
        guard let index = layout.items.firstIndex(where: { $0.id == point.id }) else { return }
        let destination = index + offset
        guard layout.items.indices.contains(destination) else { return }
        layout.items.swapAt(index, destination)
        try? persistConfiguration()
        rebuildPolling()
    }

    func moveDataPoint(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let sourceIndex = layout.items.firstIndex(where: { $0.id == id }) else { return }
        let item = layout.items.remove(at: sourceIndex)
        guard let targetIndex = layout.items.firstIndex(where: { $0.id == targetID }) else {
            layout.items.insert(item, at: sourceIndex)
            return
        }
        layout.items.insert(item, at: targetIndex)
        try? persistConfiguration()
        rebuildPolling()
    }

    func updateDataPoint(_ id: UUID, _ update: (inout DataPoint) -> Void) {
        guard let index = layout.items.firstIndex(where: { $0.id == id }) else { return }
        update(&layout.items[index])
        try? persistConfiguration()
        rebuildPolling()
    }

    func updateSeparator(_ separator: String) {
        layout.separator = separator
        try? persistConfiguration()
        rebuildPolling()
    }

    func retrySecureValueCleanup() {
        guard !pendingSecureCleanupReferences.isEmpty else {
            secureCleanupStatus = nil
            return
        }
        var unresolved: Set<UUID> = []
        let referencedByCurrentSources = Set(sources.flatMap(secureReferences(in:)))
        for reference in pendingSecureCleanupReferences {
            // A pending reference may have been recorded immediately before a
            // configuration write. Never delete it while loaded metadata still
            // points at it; a later successful mutation makes it eligible.
            guard !referencedByCurrentSources.contains(reference) else {
                unresolved.insert(reference)
                continue
            }
            do {
                try secureStore.deleteValue(for: reference)
            } catch SecureValueStoreError.notFound {
                // A missing Keychain item is already cleaned up.
            } catch {
                unresolved.insert(reference)
            }
        }
        pendingSecureCleanupReferences = unresolved
        persistPendingSecureCleanupReferences()
        if unresolved.isEmpty {
            secureCleanupStatus = nil
        } else if unresolved.allSatisfy(referencedByCurrentSources.contains) {
            secureCleanupStatus = "Secure cleanup is pending until the current configuration is replaced."
        } else {
            secureCleanupStatus = "Some old secure values could not be removed yet. They will be retried automatically."
        }
    }

    func startStreamDeckBridge() async {
        guard streamDeckServer == nil else { return }
        let backend = StreamDeckBridgeController(state: self)
        let server = StreamDeckLoopbackServer(discoveryURL: streamDeckDiscoveryURL, backend: backend)
        streamDeckServer = server
        do {
            _ = try await server.start()
        } catch {
            if streamDeckServer === server {
                streamDeckServer = nil
            }
        }
    }

    func stopStreamDeckBridge() {
        streamDeckExpiryTask?.cancel()
        streamDeckExpiryTask = nil
        streamDeckServer?.stop()
        streamDeckServer = nil
    }

    func streamDeckSources() -> [StreamDeckSourceSummary] {
        sources.map { source in
            StreamDeckSourceSummary(
                id: source.id,
                name: source.name,
                isEnabled: source.isEnabled,
                hasResponse: latestResponses[source.id] != nil,
                lastSuccess: lastSuccess[source.id],
                error: errors[source.id]
            )
        }
    }

    func refreshForStreamDeck(sourceID: UUID) async {
        guard let source = sources.first(where: { $0.id == sourceID && $0.isEnabled }) else { return }
        await refresh(source)
    }

    func streamDeckFields(sourceID: UUID) -> [StreamDeckScalarField] {
        guard let response = latestResponses[sourceID] else { return [] }
        return StreamDeckScalarCatalogue.fields(sourceID: sourceID, response: response)
    }

    func replaceStreamDeckSubscriptions(clientID: String, selections: Set<StreamDeckSelection>) {
        let timestamp = now()
        let previousSourceIDs = Set(streamDeckSelections.map(\.sourceID))
        streamDeckSubscriptions.replace(clientID: clientID, selections: selections, now: timestamp)
        streamDeckSelections = streamDeckSubscriptions.activeSelections(now: timestamp)
        streamDeckHistory.markReferenced(
            Set(streamDeckSelections.filter { $0.displayMode == .sparkline }),
            at: timestamp
        )
        streamDeckHistory.prune(inactiveBefore: timestamp.addingTimeInterval(-7 * 24 * 60 * 60))
        persistStreamDeckHistory()
        if previousSourceIDs != Set(streamDeckSelections.map(\.sourceID)) {
            rebuildPolling()
        }
        scheduleStreamDeckExpiry()
    }

    func streamDeckSnapshots(selections: Set<StreamDeckSelection>) -> [StreamDeckSnapshot] {
        selections
            .sorted {
                ($0.sourceID.uuidString, $0.jsonPointer, $0.displayMode.rawValue)
                    < ($1.sourceID.uuidString, $1.jsonPointer, $1.displayMode.rawValue)
            }
            .map { selection in
                StreamDeckSnapshotBuilder.snapshot(
                    selection: selection,
                    response: latestResponses[selection.sourceID],
                    history: streamDeckHistory.samples(for: selection),
                    isStale: errors[selection.sourceID] != nil,
                    updatedAt: lastSuccess[selection.sourceID]
                )
            }
    }

    private func save(_ draft: SourceDraft) throws -> APISource {
        retrySecureValueCleanup()
        let oldSource = sources.first { $0.id == draft.id }
        let stored: StoredSourceDraft
        do {
            stored = try draft.storeSecureValues(in: secureStore)
        } catch let error as SecureValueWriteError {
            queueSecureReferences(error.createdReferences)
            retrySecureValueCleanup()
            throw error.underlyingError
        }
        let originalSources = sources
        do {
            let source = try stored.makeSource()
            if oldSource != nil {
                // A request built from the prior source must never publish
                // into this same-ID replacement after persistence changes.
                requestGenerations.invalidate(source.id)
            }
            let oldReferences = oldSource.map(secureReferences(in:)) ?? []
            // New Keychain values already exist. Queue obsolete values before
            // committing metadata, then only delete after the new metadata is durable.
            queueSecureReferences(oldReferences)
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index] = source
            } else {
                sources.append(source)
            }
            try persistConfiguration()
            retrySecureValueCleanup()
            rebuildPolling()
            return source
        } catch {
            sources = originalSources
            if let oldSource { removeQueuedSecureReferences(secureReferences(in: oldSource)) }
            queueSecureReferences(stored.createdReferences)
            retrySecureValueCleanup()
            throw error
        }
    }

    private func refresh(_ source: APISource) async {
        await refreshGate.run(source: source) { [weak self] source in
            await self?.performRefresh(source)
        }
    }

    private func performRefresh(_ source: APISource) async {
        let generation = requestGenerations.begin(for: source.id)
        loadingSourceIDs.insert(source.id)
        defer { loadingSourceIDs.remove(source.id) }
        do {
            let response = try await client.fetch(source: source)
            guard requestGenerations.isCurrent(generation, for: source.id),
                  sources.contains(source) else { return }
            let timestamp = now()
            latestResponses[source.id] = response
            lastSuccess[source.id] = timestamp
            errors[source.id] = nil
            streamDeckHistory.record(
                response: response,
                sourceID: source.id,
                selections: streamDeckSelections,
                timestamp: timestamp
            )
            persistStreamDeckHistory()
        } catch {
            guard requestGenerations.isCurrent(generation, for: source.id),
                  sources.contains(source) else { return }
            errors[source.id] = safeMessage(for: error)
        }
    }

    private func rebuildPolling() {
        pollingConfigurationGeneration &+= 1
        let generation = pollingConfigurationGeneration
        let sourceSnapshot = sources
        let menuBarSourceIDs = Set(layout.items.map(\.sourceID))
        let streamDeckSourceIDs = Set(streamDeckSelections.map(\.sourceID))
        let activeSourceIDs = menuBarSourceIDs.union(streamDeckSourceIDs)
        let coordinator = pollingCoordinator
        Task { [weak self] in
            guard let self, self.pollingConfigurationGeneration == generation else { return }
            await coordinator.configure(sources: sourceSnapshot, activeSourceIDs: activeSourceIDs)
        }
    }

    private func persistConfiguration() throws {
        let encodedSources = try JSONEncoder().encode(sources)
        let encodedLayout = try JSONEncoder().encode(layout)
        defaults.set(encodedSources, forKey: sourcesKey)
        defaults.set(encodedLayout, forKey: layoutKey)
    }

    private func queueSecureReferences(_ references: [UUID]) {
        guard !references.isEmpty else { return }
        pendingSecureCleanupReferences.formUnion(references)
        persistPendingSecureCleanupReferences()
    }

    private func removeQueuedSecureReferences(_ references: [UUID]) {
        guard !references.isEmpty else { return }
        pendingSecureCleanupReferences.subtract(references)
        persistPendingSecureCleanupReferences()
        secureCleanupStatus = pendingSecureCleanupReferences.isEmpty ? nil : secureCleanupStatus
    }

    private func persistPendingSecureCleanupReferences() {
        defaults.set(pendingSecureCleanupReferences.map(\.uuidString), forKey: pendingSecureCleanupKey)
    }

    private func scheduleStreamDeckExpiry() {
        streamDeckExpiryTask?.cancel()
        streamDeckExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 31_000_000_000)
            guard !Task.isCancelled else { return }
            self?.expireStreamDeckSubscriptions()
        }
    }

    private func expireStreamDeckSubscriptions() {
        let previousSourceIDs = Set(streamDeckSelections.map(\.sourceID))
        streamDeckSelections = streamDeckSubscriptions.activeSelections(now: now())
        if previousSourceIDs != Set(streamDeckSelections.map(\.sourceID)) {
            rebuildPolling()
        }
    }

    private func persistStreamDeckHistory() {
        try? streamDeckHistory.save(to: streamDeckHistoryURL)
    }

    private func safeMessage(for error: Error) -> String {
        (error as? APIClientError)?.errorDescription ?? "The connection could not be completed."
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func defaultApplicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MenubarNumbers", isDirectory: true)
    }
}

private func secureReferences(in source: APISource) -> [UUID] {
    var references = source.request.headers.map(\.valueReference) + source.request.queryItems.map(\.valueReference)
    if let body = source.request.jsonBodyReference { references.append(body) }
    switch source.authentication {
    case .none:
        break
    case let .bearer(reference), let .basic(reference):
        references.append(reference)
    case let .apiKeyHeader(_, reference), let .apiKeyQuery(_, reference):
        references.append(reference)
    }
    return references
}

enum DraftAuthentication: String, CaseIterable, Identifiable {
    case none = "None"
    case bearer = "Bearer token"
    case basic = "Basic auth"
    case apiKeyHeader = "API key header"
    case apiKeyQuery = "API key query"

    var id: String { rawValue }
}

struct NamedSecret: Identifiable {
    var id = UUID()
    var name = ""
    var value = ""
}

struct SourceDraft: Identifiable {
    var id: UUID
    var name: String
    var endpoint: String
    var method: HTTPMethod
    var refreshInterval: TimeInterval
    var isEnabled: Bool
    var authentication: DraftAuthentication
    var authenticationName: String
    var authenticationValue: String
    var headers: [NamedSecret]
    var queryItems: [NamedSecret]
    var jsonBody: String

    init(source: APISource, secureStore: any SecureValueStore) {
        id = source.id
        name = source.name
        endpoint = source.request.url.absoluteString
        method = source.request.method
        refreshInterval = source.request.refreshInterval
        isEnabled = source.isEnabled
        headers = source.request.headers.map { NamedSecret(name: $0.name, value: (try? secureStore.value(for: $0.valueReference)) ?? "") }
        queryItems = source.request.queryItems.map { NamedSecret(name: $0.name, value: (try? secureStore.value(for: $0.valueReference)) ?? "") }
        jsonBody = source.request.jsonBodyReference.flatMap { try? secureStore.value(for: $0) } ?? ""
        switch source.authentication {
        case .none:
            authentication = .none; authenticationName = ""; authenticationValue = ""
        case let .bearer(reference):
            authentication = .bearer; authenticationName = ""; authenticationValue = (try? secureStore.value(for: reference)) ?? ""
        case let .basic(reference):
            authentication = .basic; authenticationName = ""; authenticationValue = (try? secureStore.value(for: reference)) ?? ""
        case let .apiKeyHeader(name, reference):
            authentication = .apiKeyHeader; authenticationName = name; authenticationValue = (try? secureStore.value(for: reference)) ?? ""
        case let .apiKeyQuery(name, reference):
            authentication = .apiKeyQuery; authenticationName = name; authenticationValue = (try? secureStore.value(for: reference)) ?? ""
        }
    }

    func storeSecureValues(in store: any SecureValueStore) throws -> StoredSourceDraft {
        var created: [UUID] = []
        func create(_ value: String) throws -> UUID {
            let reference = UUID()
            try store.set(value, for: reference)
            created.append(reference)
            return reference
        }

        do {
            let storedHeaders = try headers.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
                RequestHeader(name: $0.name, valueReference: try create($0.value))
            }
            let storedQueryItems = try queryItems.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
                RequestQueryItem(name: $0.name, valueReference: try create($0.value))
            }
            let bodyReference = jsonBody.isEmpty ? nil : try create(jsonBody)
            let storedAuthentication: AuthenticationConfiguration
            switch authentication {
            case .none:
                storedAuthentication = .none
            case .bearer:
                storedAuthentication = .bearer(credentialReference: try create(authenticationValue))
            case .basic:
                storedAuthentication = .basic(credentialReference: try create(authenticationValue))
            case .apiKeyHeader:
                storedAuthentication = .apiKeyHeader(name: authenticationName, credentialReference: try create(authenticationValue))
            case .apiKeyQuery:
                storedAuthentication = .apiKeyQuery(name: authenticationName, credentialReference: try create(authenticationValue))
            }
            return StoredSourceDraft(draft: self, headers: storedHeaders, queryItems: storedQueryItems, bodyReference: bodyReference, authentication: storedAuthentication, createdReferences: created)
        } catch {
            throw SecureValueWriteError(underlyingError: error, createdReferences: created)
        }
    }
}

struct SecureValueWriteError: Error {
    let underlyingError: Error
    let createdReferences: [UUID]
}

struct StoredSourceDraft {
    let draft: SourceDraft
    let headers: [RequestHeader]
    let queryItems: [RequestQueryItem]
    let bodyReference: UUID?
    let authentication: AuthenticationConfiguration
    let createdReferences: [UUID]

    func makeSource() throws -> APISource {
        guard let url = URL(string: draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw APIClientError.invalidConfiguration
        }
        let request = APIRequestConfiguration(method: draft.method, url: url, headers: headers, queryItems: queryItems, jsonBodyReference: bodyReference, refreshInterval: draft.refreshInterval)
        try request.validate()
        return APISource(id: draft.id, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled API" : draft.name, request: request, authentication: authentication, isEnabled: draft.isEnabled)
    }

}
