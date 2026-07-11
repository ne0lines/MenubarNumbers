import Foundation

/// Tracks which in-flight request is authoritative for each source. A caller
/// captures the generation returned by `begin(for:)` and mutates UI state only
/// when that generation remains current after awaiting network work.
public struct SourceRequestGenerations: Sendable {
    private var values: [UUID: UInt64] = [:]

    public init() {}

    public mutating func begin(for sourceID: UUID) -> UInt64 {
        let next = (values[sourceID] ?? 0) &+ 1
        values[sourceID] = next
        return next
    }

    public func isCurrent(_ generation: UInt64, for sourceID: UUID) -> Bool {
        values[sourceID] == generation
    }

    /// Invalidates any captured generation without starting a new request.
    public mutating func invalidate(_ sourceID: UUID) {
        _ = begin(for: sourceID)
    }
}
