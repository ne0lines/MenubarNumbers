import SwiftUI
import UniformTypeIdentifiers
import MenubarNumbersCore

struct JSONInspectorView: View {
    let source: APISource
    let response: JSONValue

    var body: some View {
        GroupBox("JSON response — drag scalar values to the Menu Bar builder") {
            List {
                OutlineGroup([response.tree], children: \.nestedChildren) { node in
                    JSONTreeRow(sourceID: source.id, node: node)
                }
            }
            .frame(minHeight: 240)
        }
        .accessibilityLabel("JSON response inspector")
    }
}

private struct JSONTreeRow: View {
    let sourceID: UUID
    let node: JSONValueTreeNode

    var body: some View {
        HStack(spacing: 8) {
            Text(node.label)
                .fontWeight(node.scalarDescription == nil ? .semibold : .regular)
            Text(node.pointer.isEmpty ? "/" : node.pointer)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            if let value = node.scalarDescription {
                Text(value)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .onDrag {
                        let token = JSONDragToken(sourceID: sourceID, pointer: node.pointer, label: node.label)
                        return NSItemProvider(object: token.encoded as NSString)
                    }
                    .accessibilityLabel("Drag \(node.label) with value \(value) to Menu Bar")
            }
        }
    }
}

struct JSONDragToken: Codable {
    let sourceID: UUID
    let pointer: String
    let label: String

    var encoded: String {
        String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? ""
    }
}
