import SwiftUI
import UniformTypeIdentifiers
import MenubarNumbersCore

struct MenuBarBuilderView: View {
    @ObservedObject var state: AppState
    @State private var isDropTarget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Simulated menu bar")
                        .font(.headline)
                    HStack {
                        Image(systemName: "apple.logo")
                        Spacer()
                        Text(state.menuBarText)
                            .lineLimit(1)
                        Image(systemName: "wifi")
                        Text("12:00")
                    }
                    .padding(10)
                    .background(isDropTarget ? Color.accentColor.opacity(0.24) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .onDrop(of: [UTType.utf8PlainText], isTargeted: $isDropTarget, perform: acceptDrop)
                    .accessibilityLabel("Simulated menu bar drop area")
                    Text("Drag a scalar JSON value here. The same preview appears in the real menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Separator")
                    TextField("Separator", text: Binding(get: { state.layout.separator }, set: state.updateSeparator))
                        .frame(maxWidth: 180)
                        .accessibilityLabel("Menu bar item separator")
                }

                if state.layout.items.isEmpty {
                    ContentUnavailableView("No selected values", systemImage: "menubar.rectangle", description: Text("Test a source, then drag a scalar JSON value into the simulated menu bar."))
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ForEach(state.layout.items) { point in
                        DataPointEditor(state: state, point: point)
                            .onDrag {
                                let token = MenuBarItemDragToken(dataPointID: point.id)
                                return NSItemProvider(object: token.encoded as NSString)
                            }
                            .onDrop(of: [UTType.utf8PlainText], isTargeted: nil) { providers in
                                acceptItemReorder(providers, before: point.id)
                            }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Menu Bar Builder")
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let data = string.data(using: .utf8),
                  let token = try? JSONDecoder().decode(JSONDragToken.self, from: data) else { return }
            DispatchQueue.main.async {
                state.addDataPoint(sourceID: token.sourceID, pointer: token.pointer, label: token.label)
            }
        }
        return true
    }

    private func acceptItemReorder(_ providers: [NSItemProvider], before targetID: UUID) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let data = string.data(using: .utf8),
                  let token = try? JSONDecoder().decode(MenuBarItemDragToken.self, from: data) else { return }
            DispatchQueue.main.async {
                state.moveDataPoint(id: token.dataPointID, before: targetID)
            }
        }
        return true
    }
}

private struct MenuBarItemDragToken: Codable {
    let dataPointID: UUID

    var encoded: String {
        String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? ""
    }
}

private struct DataPointEditor: View {
    @ObservedObject var state: AppState
    let point: DataPoint

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(point.jsonPointer.isEmpty ? "/" : point.jsonPointer)
                        .font(.caption.monospaced())
                    Spacer()
                    Button { state.moveDataPoint(point, by: -1) } label: { Image(systemName: "arrow.up") }
                        .accessibilityLabel("Move \(point.label) up")
                    Button { state.moveDataPoint(point, by: 1) } label: { Image(systemName: "arrow.down") }
                        .accessibilityLabel("Move \(point.label) down")
                    Button { state.removeDataPoint(point) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Remove \(point.label) from menu bar")
                }
                TextField("Label", text: labelBinding)
                    .accessibilityLabel("Menu bar item label")
                TextField("Template", text: formatBinding)
                    .accessibilityLabel("Menu bar template")
                TextField("Fallback", text: fallbackBinding)
                    .accessibilityLabel("Menu bar fallback value")
                HStack {
                    Picker("Decimals", selection: decimalBinding) {
                        Text("Automatic").tag(Int?.none)
                        ForEach(0...6, id: \.self) { places in
                            Text("\(places)").tag(Optional(places))
                        }
                    }
                    .accessibilityLabel("Number decimal places")
                    Picker("Date style", selection: dateStyleBinding) {
                        ForEach(MenuBarDateStyle.allCases, id: \.self) { style in
                            Text(style.rawValue.capitalized).tag(style)
                        }
                    }
                    .accessibilityLabel("Date display style")
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text(point.label)
        }
    }

    private var sourceName: String {
        state.sources.first(where: { $0.id == point.sourceID })?.name ?? "Deleted source"
    }

    private var labelBinding: Binding<String> {
        Binding(get: { point.label }, set: { value in state.updateDataPoint(point.id) { $0.label = value } })
    }

    private var formatBinding: Binding<String> {
        Binding(get: { point.format }, set: { value in state.updateDataPoint(point.id) { $0.format = value } })
    }

    private var fallbackBinding: Binding<String> {
        Binding(get: { point.fallback }, set: { value in state.updateDataPoint(point.id) { $0.fallback = value } })
    }

    private var decimalBinding: Binding<Int?> {
        Binding(get: { point.numberDecimalPlaces }, set: { value in state.updateDataPoint(point.id) { $0.numberDecimalPlaces = value } })
    }

    private var dateStyleBinding: Binding<MenuBarDateStyle> {
        Binding(get: { point.dateStyle }, set: { value in state.updateDataPoint(point.id) { $0.dateStyle = value } })
    }
}
