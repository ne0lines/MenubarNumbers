import Foundation

/// Serializes every network refresh for a source, regardless of whether it was
/// requested by polling or a user action. Repeated requests for the same
/// configuration coalesce; a changed configuration is run once after the
/// current request completes.
public actor SourceRefreshGate {
    public typealias Operation = @Sendable (APISource) async -> Void

    private struct Request: Sendable {
        let source: APISource
        let operation: Operation
        var interestedWaiterIDs: Set<UUID>
    }

    private var active: [UUID: Request] = [:]
    private var pending: [UUID: Request] = [:]
    private var waiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []

    public init() {}

    public func run(source: APISource, operation: @escaping Operation) async {
        if let current = active[source.id] {
            let waiterID = UUID()
            if current.source != source {
                if var replacement = pending[source.id], replacement.source == source {
                    replacement.interestedWaiterIDs.insert(waiterID)
                    pending[source.id] = replacement
                } else {
                    pending[source.id] = Request(
                        source: source,
                        operation: operation,
                        interestedWaiterIDs: [waiterID]
                    )
                }
            }
            await waitForCompletion(of: source.id, waiterID: waiterID)
            return
        }

        var request = Request(source: source, operation: operation, interestedWaiterIDs: [])
        active[source.id] = request
        while true {
            await request.operation(request.source)
            guard let replacement = pending.removeValue(forKey: source.id) else { break }
            request = replacement
            active[source.id] = request
        }

        active[source.id] = nil
        let sourceWaiters = waiters.removeValue(forKey: source.id) ?? [:]
        sourceWaiters.values.forEach { $0.resume() }
    }

    func pendingWaiterCount() -> Int {
        waiters.values.reduce(0) { $0 + $1.count }
    }

    private func waitForCompletion(of sourceID: UUID, waiterID: UUID) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledWaiterIDs.remove(waiterID) != nil || active[sourceID] == nil {
                    continuation.resume()
                } else {
                    waiters[sourceID, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, sourceID: sourceID) }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, sourceID: UUID) {
        if let continuation = waiters[sourceID]?.removeValue(forKey: waiterID) {
            continuation.resume()
        } else if active[sourceID] != nil {
            cancelledWaiterIDs.insert(waiterID)
        }

        if var replacement = pending[sourceID], replacement.interestedWaiterIDs.remove(waiterID) != nil {
            if replacement.interestedWaiterIDs.isEmpty {
                pending[sourceID] = nil
            } else {
                pending[sourceID] = replacement
            }
        }
    }
}
