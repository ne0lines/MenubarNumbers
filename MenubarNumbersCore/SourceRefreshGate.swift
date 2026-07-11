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
    }

    private var active: [UUID: Request] = [:]
    private var pending: [UUID: Request] = [:]
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func run(source: APISource, operation: @escaping Operation) async {
        if let current = active[source.id] {
            if current.source != source {
                pending[source.id] = Request(source: source, operation: operation)
            }
            await waitForCompletion(of: source.id)
            return
        }

        var request = Request(source: source, operation: operation)
        active[source.id] = request
        while true {
            await request.operation(request.source)
            guard let replacement = pending.removeValue(forKey: source.id) else { break }
            request = replacement
            active[source.id] = request
        }

        active[source.id] = nil
        let sourceWaiters = waiters.removeValue(forKey: source.id) ?? []
        sourceWaiters.forEach { $0.resume() }
    }

    private func waitForCompletion(of sourceID: UUID) async {
        await withCheckedContinuation { continuation in
            waiters[sourceID, default: []].append(continuation)
        }
    }
}
