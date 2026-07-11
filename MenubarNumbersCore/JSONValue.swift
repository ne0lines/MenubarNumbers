import Foundation
import CoreFoundation

public enum JSONPointerError: Error, Equatable, LocalizedError, Sendable {
    case invalidPointer(String)
    case missingValue(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPointer(pointer):
            return "Invalid JSON Pointer: \(pointer)"
        case let .missingValue(pointer):
            return "No JSON value exists at pointer: \(pointer)"
        }
    }
}

public enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null

    public static func parse(_ data: Data) throws -> JSONValue {
        try from(jsonObject: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public func value(at pointer: String) throws -> JSONValue {
        if pointer.isEmpty { return self }
        guard pointer.first == "/" else { throw JSONPointerError.invalidPointer(pointer) }

        var current = self
        for rawToken in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = try unescape(String(rawToken), pointer: pointer)
            switch current {
            case let .object(values):
                guard let next = values[token] else { throw JSONPointerError.missingValue(pointer) }
                current = next
            case let .array(values):
                guard let index = validArrayIndex(token) else { throw JSONPointerError.invalidPointer(pointer) }
                guard values.indices.contains(index) else { throw JSONPointerError.missingValue(pointer) }
                current = values[index]
            default:
                throw JSONPointerError.missingValue(pointer)
            }
        }
        return current
    }

    public var tree: JSONValueTreeNode {
        JSONValueTreeNode(value: self, label: "root", pointer: "")
    }

    private static func from(jsonObject: Any) throws -> JSONValue {
        switch jsonObject {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            guard let decimal = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")) else {
                throw JSONValueParsingError.unsupportedNumber
            }
            return .number(decimal)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(try array.map(from(jsonObject:)))
        case let dictionary as [String: Any]:
            return .object(try dictionary.mapValues(from(jsonObject:)))
        default:
            throw JSONValueParsingError.unsupportedValue
        }
    }

    private func unescape(_ token: String, pointer: String) throws -> String {
        var result = ""
        var index = token.startIndex
        while index < token.endIndex {
            let character = token[index]
            guard character == "~" else {
                result.append(character)
                index = token.index(after: index)
                continue
            }
            let next = token.index(after: index)
            guard next < token.endIndex else { throw JSONPointerError.invalidPointer(pointer) }
            switch token[next] {
            case "0": result.append("~")
            case "1": result.append("/")
            default: throw JSONPointerError.invalidPointer(pointer)
            }
            index = token.index(after: next)
        }
        return result
    }

    private func validArrayIndex(_ token: String) -> Int? {
        guard !token.isEmpty, token.allSatisfy(\.isNumber), token == "0" || !token.hasPrefix("0") else { return nil }
        return Int(token)
    }
}

public enum JSONValueParsingError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedNumber
    case unsupportedValue

    public var errorDescription: String? { "The response cannot be represented as a JSON value." }
}

public struct JSONValueTreeNode: Identifiable, Equatable, Sendable {
    public let value: JSONValue
    public let label: String
    public let pointer: String
    public let children: [JSONValueTreeNode]

    public var id: String { pointer }
    public var nestedChildren: [JSONValueTreeNode]? { children.isEmpty ? nil : children }

    init(value: JSONValue, label: String, pointer: String) {
        self.value = value
        self.label = label
        self.pointer = pointer
        switch value {
        case let .object(values):
            children = values.keys.sorted().map { key in
                JSONValueTreeNode(value: values[key]!, label: key, pointer: pointer + "/" + Self.escape(key))
            }
        case let .array(values):
            children = values.enumerated().map { index, child in
                JSONValueTreeNode(value: child, label: String(index), pointer: pointer + "/\(index)")
            }
        default:
            children = []
        }
    }

    public var scalarDescription: String? {
        switch value {
        case let .string(value): return value
        case let .number(value): return NSDecimalNumber(decimal: value).stringValue
        case let .bool(value): return value ? "true" : "false"
        case .null: return "null"
        case .object, .array: return nil
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
}
