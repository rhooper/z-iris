import Foundation

/// Field access on JSONSerialization objects, throwing MalformedEvent where the
/// Python code would raise KeyError or TypeError.
extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) throws -> Int {
        guard let value = self[key].flatMap(jsonInt) else { throw MalformedEvent(reason: key) }
        return value
    }

    func string(_ key: String) throws -> String {
        guard let value = self[key] as? String else { throw MalformedEvent(reason: key) }
        return value
    }

    func list(_ key: String) -> [Any] {
        self[key] as? [Any] ?? []
    }

    /// Python truthiness for the scalar values Zulip sends.
    func truthy(_ key: String) -> Bool {
        switch self[key] {
        case let number as NSNumber: number.doubleValue != 0
        case let text as String: !text.isEmpty
        case let list as [Any]: !list.isEmpty
        case let dict as [String: Any]: !dict.isEmpty
        default: false
        }
    }
}

/// An integer from JSON. JSONSerialization gives NSNumber, and a Bool also
/// bridges to Int, so refuse booleans and floating point numbers.
public func jsonInt(_ value: Any) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          !"df".contains(String(cString: number.objCType))
    else { return nil }
    return number.intValue
}
