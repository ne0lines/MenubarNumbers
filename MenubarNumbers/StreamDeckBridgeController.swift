import Foundation
import MenubarNumbersCore

final class StreamDeckBridgeController: StreamDeckBridgeBackend, @unchecked Sendable {
    @MainActor private weak var state: AppState?

    @MainActor init(state: AppState) {
        self.state = state
    }

    func sources() async -> [StreamDeckSourceSummary] {
        await MainActor.run { state?.streamDeckSources() ?? [] }
    }

    func fields(sourceID: UUID, refresh: Bool) async -> [StreamDeckScalarField] {
        guard let state = await MainActor.run(body: { self.state }) else { return [] }
        if refresh {
            await state.refreshForStreamDeck(sourceID: sourceID)
        }
        return await MainActor.run { state.streamDeckFields(sourceID: sourceID) }
    }

    func replaceSubscriptions(clientID: String, selections: Set<StreamDeckSelection>) async {
        guard let state = await MainActor.run(body: { self.state }) else { return }
        await state.replaceStreamDeckSubscriptions(clientID: clientID, selections: selections)
    }

    func snapshots(selections: Set<StreamDeckSelection>) async -> [StreamDeckSnapshot] {
        guard let state = await MainActor.run(body: { self.state }) else { return [] }
        return await MainActor.run { state.streamDeckSnapshots(selections: selections) }
    }
}
