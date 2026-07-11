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
        var interestedWaiters: [UUID: CancellationToken]
    }

    private var active: [UUID: Request] = [:]
    private var pending: [UUID: Request] = [:]
    private var waiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []

    public init() {}

    public func run(source: APISource, operation: @escaping Operation) async {
        if let current = active[source.id] {
            let waiterID = UUID()
            let cancellationToken: CancellationToken?
            if current.source != source {
                let replacementCancellationToken = CancellationToken()
                cancellationToken = replacementCancellationToken
                if var replacement = pending[source.id], replacement.source == source {
                    replacement.interestedWaiters[waiterID] = replacementCancellationToken
                    pending[source.id] = replacement
                } else {
                    pending[source.id] = Request(
                        source: source,
                        operation: operation,
                        interestedWaiters: [waiterID: replacementCancellationToken]
                    )
                }
            } else {
                cancellationToken = nil
            }
            await waitForCompletion(
                of: source.id,
                waiterID: waiterID,
                cancellationToken: cancellationToken
            )
            return
        }

        var request = Request(source: source, operation: operation, interestedWaiters: [:])
        active[source.id] = request
        while true {
            await request.operation(request.source)
            guard let replacement = pending.removeValue(forKey: source.id) else { break }
            guard replacement.interestedWaiters.values.contains(where: { !$0.isCancelled }) else { break }
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

    private func waitForCompletion(
        of sourceID: UUID,
        waiterID: UUID,
        cancellationToken: CancellationToken?
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledWaiterIDs.remove(waiterID) != nil || active[sourceID] == nil {
                    continuation.resume()
                } else {
                    waiters[sourceID, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            cancellationToken?.cancel()
            Task { await self.cancelWaiter(waiterID, sourceID: sourceID) }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, sourceID: UUID) {
        if let continuation = waiters[sourceID]?.removeValue(forKey: waiterID) {
            continuation.resume()
        } else if active[sourceID] != nil {
            cancelledWaiterIDs.insert(waiterID)
        }

        if var replacement = pending[sourceID], replacement.interestedWaiters.removeValue(forKey: waiterID) != nil {
            if replacement.interestedWaiters.isEmpty {
                pending[sourceID] = nil
            } else {
                pending[sourceID] = replacement
            }
        }
    }
}

private final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
