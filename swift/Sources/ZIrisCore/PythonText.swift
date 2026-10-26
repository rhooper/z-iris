import Foundation

extension String {
    /// Python's str.lower(): the full lowercase mapping plus the Final_Sigma
    /// rule (a capital sigma ending a word becomes ς), which lowercased() skips.
    /// Keys lowercased here must match what the Python version stored.
    public var pythonLowercased: String {
        let scalars = Array(unicodeScalars)
        var out = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\u{03A3}", Self.isFinalSigma(scalars, at: index) {
                out.append("\u{03C2}")
            } else {
                out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(out)
    }

    private static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let before = scalars[..<index].reversed().first { !$0.properties.isCaseIgnorable }
        let after = scalars[(index + 1)...].first { !$0.properties.isCaseIgnorable }
        return before?.properties.isCased == true && after?.properties.isCased != true
    }
}

/// Python's repr() for the values a TOML config can hold, so error messages
/// read the same as the Python version's.
public func pythonRepr(_ value: Any?) -> String {
    switch value {
    case nil: return "None"
    case let text as String: return pythonRepr(string: text)
    case let flag as Bool: return flag ? "True" : "False"
    case let number as Int64: return String(number)
    case let number as Int: return String(number)
    case let number as Double:
        if number.isNaN { return "nan" }
        if number.isInfinite { return number < 0 ? "-inf" : "inf" }
        return number.description
    case let list as [Any]: return "[" + list.map { pythonRepr($0) }.joined(separator: ", ") + "]"
    case let table as [String: Any]:
        return "{" + table.map { "\(pythonRepr(string: $0.key)): \(pythonRepr($0.value))" }
            .joined(separator: ", ") + "}"
    default: return String(describing: value!)
    }
}

private func pythonRepr(string text: String) -> String {
    let quote: Character = text.contains("'") && !text.contains("\"") ? "\"" : "'"
    var out = String(quote)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where Character(scalar) == quote: out += "\\\(quote)"
        case _ where isPrintable(scalar): out.unicodeScalars.append(scalar)
        case _ where scalar.value < 0x100: out += String(format: "\\x%02x", scalar.value)
        case _ where scalar.value < 0x10000: out += String(format: "\\u%04x", scalar.value)
        default: out += String(format: "\\U%08x", scalar.value)
        }
    }
    return out + String(quote)
}

// str.isprintable(): not Other or Separator, except the ASCII space.
private func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == " " { return true }
    switch scalar.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned,
         .lineSeparator, .paragraphSeparator, .spaceSeparator:
        return false
    default:
        return true
    }
}
