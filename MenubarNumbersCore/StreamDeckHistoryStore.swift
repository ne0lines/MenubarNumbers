import Foundation

public struct StreamDeckHistoryStore: Sendable {
    private struct Key: Hashable, Sendable {
        let sourceID: UUID
        let jsonPointer: String
    }

    private struct Entry: Sendable {
        var samples: [StreamDeckHistorySample]
        var lastReferencedAt: Date
    }

    private struct PersistedEntry: Codable {
        let sourceID: UUID
        let jsonPointer: String
        let samples: [StreamDeckHistorySample]
        let lastReferencedAt: Date
    }

    private let limit: Int
    private var entries: [Key: Entry] = [:]

    public init(limit: Int = 60) {
        self.limit = max(1, limit)
    }

    public mutating func record(
        response: JSONValue,
        sourceID: UUID,
        selections: Set<StreamDeckSelection>,
        timestamp: Date
    ) {
        for selection in selections where selection.sourceID == sourceID && selection.displayMode == .sparkline {
            guard case let .number(number) = try? response.value(at: selection.jsonPointer) else { continue }
            let key = Key(sourceID: sourceID, jsonPointer: selection.jsonPointer)
            var entry = entries[key] ?? Entry(samples: [], lastReferencedAt: timestamp)
            entry.samples.append(
                StreamDeckHistorySample(
                    timestamp: timestamp,
                    value: NSDecimalNumber(decimal: number).doubleValue
                )
            )
            entry.samples = Array(entry.samples.suffix(limit))
            entry.lastReferencedAt = timestamp
            entries[key] = entry
        }
    }

    public func samples(for selection: StreamDeckSelection) -> [StreamDeckHistorySample] {
        entries[Key(sourceID: selection.sourceID, jsonPointer: selection.jsonPointer)]?.samples ?? []
    }

    public mutating func markReferenced(_ selections: Set<StreamDeckSelection>, at date: Date) {
        for selection in selections {
            let key = Key(sourceID: selection.sourceID, jsonPointer: selection.jsonPointer)
            var entry = entries[key] ?? Entry(samples: [], lastReferencedAt: date)
            entry.lastReferencedAt = date
            entries[key] = entry
        }
    }

    public mutating func prune(inactiveBefore cutoff: Date) {
        entries = entries.filter { $0.value.lastReferencedAt >= cutoff }
    }

    public mutating func remove(sourceID: UUID) {
        entries = entries.filter { $0.key.sourceID != sourceID }
    }

    public func containsHistory(for selection: StreamDeckSelection) -> Bool {
        entries[Key(sourceID: selection.sourceID, jsonPointer: selection.jsonPointer)] != nil
    }

    public func save(to url: URL) throws {
        let values = entries.map { key, entry in
            PersistedEntry(
                sourceID: key.sourceID,
                jsonPointer: key.jsonPointer,
                samples: entry.samples,
                lastReferencedAt: entry.lastReferencedAt
            )
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
    }

    public static func load(from url: URL, limit: Int = 60) -> StreamDeckHistoryStore {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([PersistedEntry].self, from: data) else {
            return StreamDeckHistoryStore(limit: limit)
        }
        var store = StreamDeckHistoryStore(limit: limit)
        for value in values {
            let key = Key(sourceID: value.sourceID, jsonPointer: value.jsonPointer)
            store.entries[key] = Entry(
                samples: Array(value.samples.suffix(store.limit)),
                lastReferencedAt: value.lastReferencedAt
            )
        }
        return store
    }
}
