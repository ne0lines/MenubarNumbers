import Foundation

public struct StreamDeckSubscriptionRegistry: Sendable {
    private struct Lease: Sendable {
        let selections: Set<StreamDeckSelection>
        let expiresAt: Date
    }

    private let leaseDuration: TimeInterval
    private var leases: [String: Lease] = [:]

    public init(leaseDuration: TimeInterval = 30) {
        self.leaseDuration = leaseDuration
    }

    public mutating func replace(clientID: String, selections: Set<StreamDeckSelection>, now: Date) {
        leases[clientID] = Lease(
            selections: selections,
            expiresAt: now.addingTimeInterval(leaseDuration)
        )
    }

    public mutating func activeSelections(now: Date) -> Set<StreamDeckSelection> {
        leases = leases.filter { $0.value.expiresAt > now }
        return leases.values.reduce(into: Set<StreamDeckSelection>()) { result, lease in
            result.formUnion(lease.selections)
        }
    }
}
