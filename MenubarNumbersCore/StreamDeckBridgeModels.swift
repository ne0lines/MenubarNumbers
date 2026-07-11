import Foundation

public enum StreamDeckScalarType: String, Codable, Sendable {
    case string
    case number
    case boolean
    case null
}

public enum StreamDeckDisplayMode: String, Codable, Sendable {
    case value
    case sparkline
}

public enum StreamDeckValueStatus: String, Codable, Sendable {
    case fresh
    case stale
    case missing
}

public struct StreamDeckSelection: Codable, Hashable, Sendable {
    public let sourceID: UUID
    public let jsonPointer: String
    public let displayMode: StreamDeckDisplayMode

    public init(sourceID: UUID, jsonPointer: String, displayMode: StreamDeckDisplayMode) {
        self.sourceID = sourceID
        self.jsonPointer = jsonPointer
        self.displayMode = displayMode
    }
}

public struct StreamDeckSourceSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let isEnabled: Bool
    public let hasResponse: Bool
    public let lastSuccess: Date?
    public let error: String?

    public init(id: UUID, name: String, isEnabled: Bool, hasResponse: Bool, lastSuccess: Date?, error: String?) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.hasResponse = hasResponse
        self.lastSuccess = lastSuccess
        self.error = error
    }
}

public struct StreamDeckScalarField: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let jsonPointer: String
    public let label: String
    public let type: StreamDeckScalarType
    public let value: String
    public let numericValue: Double?

    public init(
        sourceID: UUID,
        jsonPointer: String,
        label: String,
        type: StreamDeckScalarType,
        value: String,
        numericValue: Double?
    ) {
        self.sourceID = sourceID
        self.jsonPointer = jsonPointer
        self.label = label
        self.type = type
        self.value = value
        self.numericValue = numericValue
    }
}

public struct StreamDeckHistorySample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let value: Double

    public init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}

public struct StreamDeckSnapshot: Codable, Equatable, Sendable {
    public let selection: StreamDeckSelection
    public let type: StreamDeckScalarType?
    public let value: String?
    public let numericValue: Double?
    public let history: [StreamDeckHistorySample]
    public let status: StreamDeckValueStatus
    public let updatedAt: Date?

    public init(
        selection: StreamDeckSelection,
        type: StreamDeckScalarType?,
        value: String?,
        numericValue: Double?,
        history: [StreamDeckHistorySample],
        status: StreamDeckValueStatus,
        updatedAt: Date?
    ) {
        self.selection = selection
        self.type = type
        self.value = value
        self.numericValue = numericValue
        self.history = history
        self.status = status
        self.updatedAt = updatedAt
    }
}

public enum StreamDeckScalarCatalogue {
    public static func fields(sourceID: UUID, response: JSONValue) -> [StreamDeckScalarField] {
        flatten(node: response.tree, sourceID: sourceID).sorted { $0.jsonPointer < $1.jsonPointer }
    }

    public static func field(sourceID: UUID, pointer: String, response: JSONValue) -> StreamDeckScalarField? {
        guard let value = try? response.value(at: pointer) else { return nil }
        return makeField(sourceID: sourceID, pointer: pointer, label: pointerLabel(pointer), value: value)
    }

    private static func flatten(node: JSONValueTreeNode, sourceID: UUID) -> [StreamDeckScalarField] {
        if let field = makeField(sourceID: sourceID, pointer: node.pointer, label: node.label, value: node.value) {
            return [field]
        }
        return node.children.flatMap { flatten(node: $0, sourceID: sourceID) }
    }

    private static func makeField(
        sourceID: UUID,
        pointer: String,
        label: String,
        value: JSONValue
    ) -> StreamDeckScalarField? {
        switch value {
        case let .string(string):
            return StreamDeckScalarField(
                sourceID: sourceID,
                jsonPointer: pointer,
                label: label,
                type: .string,
                value: string,
                numericValue: nil
            )
        case let .number(number):
            return StreamDeckScalarField(
                sourceID: sourceID,
                jsonPointer: pointer,
                label: label,
                type: .number,
                value: NSDecimalNumber(decimal: number).stringValue,
                numericValue: NSDecimalNumber(decimal: number).doubleValue
            )
        case let .bool(boolean):
            return StreamDeckScalarField(
                sourceID: sourceID,
                jsonPointer: pointer,
                label: label,
                type: .boolean,
                value: boolean ? "true" : "false",
                numericValue: nil
            )
        case .null:
            return StreamDeckScalarField(
                sourceID: sourceID,
                jsonPointer: pointer,
                label: label,
                type: .null,
                value: "null",
                numericValue: nil
            )
        case .object, .array:
            return nil
        }
    }

    private static func pointerLabel(_ pointer: String) -> String {
        guard let raw = pointer.split(separator: "/", omittingEmptySubsequences: false).last else { return "root" }
        return raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}

public enum StreamDeckSnapshotBuilder {
    public static func snapshot(
        selection: StreamDeckSelection,
        response: JSONValue?,
        history: [StreamDeckHistorySample],
        isStale: Bool,
        updatedAt: Date?
    ) -> StreamDeckSnapshot {
        guard let response,
              let field = StreamDeckScalarCatalogue.field(
                sourceID: selection.sourceID,
                pointer: selection.jsonPointer,
                response: response
              ) else {
            return StreamDeckSnapshot(
                selection: selection,
                type: nil,
                value: nil,
                numericValue: nil,
                history: [],
                status: .missing,
                updatedAt: updatedAt
            )
        }
        return StreamDeckSnapshot(
            selection: selection,
            type: field.type,
            value: field.value,
            numericValue: field.numericValue,
            history: selection.displayMode == .sparkline ? history : [],
            status: isStale ? .stale : .fresh,
            updatedAt: updatedAt
        )
    }
}
