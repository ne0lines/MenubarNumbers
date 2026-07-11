import Foundation

/// Pure rendering of the configured layout. Keeping this in Core ensures the
/// app preview and the real status item always use the exact same rules.
public enum MenuBarTextRenderer {
    public static func render(layout: MenuBarLayout, responses: [UUID: JSONValue]) -> String {
        renderItems(layout: layout, responses: responses).joined(separator: layout.separator)
    }

    public static func renderItems(layout: MenuBarLayout, responses: [UUID: JSONValue]) -> [String] {
        layout.items.map { point in
            let value = responses[point.sourceID].flatMap { try? $0.value(at: point.jsonPointer) }
            let renderedValue = value.flatMap { scalarText(for: $0, point: point) } ?? point.fallback
            return point.format
                .replacingOccurrences(of: "{label}", with: point.label)
                .replacingOccurrences(of: "{value}", with: renderedValue)
        }
    }

    private static func scalarText(for value: JSONValue, point: DataPoint) -> String? {
        switch value {
        case let .number(number):
            return render(number: number, decimalPlaces: point.numberDecimalPlaces)
        case let .string(string):
            return render(dateString: string, style: point.dateStyle) ?? string
        case let .bool(bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        case .object, .array:
            return nil
        }
    }

    private static func render(number: Decimal, decimalPlaces: Int?) -> String {
        guard let decimalPlaces else {
            return NSDecimalNumber(decimal: number).stringValue
        }
        var divisor = Decimal(1)
        for _ in 0..<max(0, decimalPlaces) {
            divisor *= 10
        }
        let scaledNumber = number / divisor

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = max(0, decimalPlaces)
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: scaledNumber)) ?? NSDecimalNumber(decimal: scaledNumber).stringValue
    }

    private static func render(dateString: String, style: MenuBarDateStyle) -> String? {
        guard style != .none else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: dateString) else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        switch style {
        case .none:
            return nil
        case .short:
            dateFormatter.dateFormat = "yyyy-MM-dd"
        case .medium:
            dateFormatter.dateFormat = "MMM d, yyyy"
        case .long:
            dateFormatter.dateFormat = "MMMM d, yyyy"
        }
        return dateFormatter.string(from: date)
    }
}
