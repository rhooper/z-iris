import Foundation
import Testing
@testable import ZIrisCore

/// A JSON value from the payload as the TOMLValue the editor would send.
private func value(_ json: Any) -> TOMLValue {
    switch json {
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
        return .bool(number.boolValue)
    case let number as NSNumber where "df".contains(String(cString: number.objCType)):
        return .float(number.doubleValue)
    case let number as NSNumber:
        return .integer(number.intValue)
    case let text as String:
        return .string(text)
    case let list as [Any]:
        return .array(list.map(value))
    default:
        fatalError("no TOMLValue for \(json)")
    }
}

private func fields(_ json: Any?) -> [String: TOMLValue]? {
    (json as? [String: Any])?.mapValues(value)
}

private func payload(_ json: [String: Any]) -> EditPayload {
    EditPayload(
        defaults: fields(json["defaults"]),
        focus: fields(json["focus"]),
        servers: (json["servers"] as? [[String: Any]] ?? []).map { ($0["name"] as! String, $0["volume"].map(value)) },
        rules: (json["rules"] as? [[String: Any]])?.map { $0.mapValues(value) }
    )
}

private func plain(_ value: TOMLValue) -> Any {
    switch value {
    case .string(let text): text
    case .integer(let number): number
    case .float(let number): number
    case .bool(let flag): flag
    case .array(let items): items.map(plain)
    }
}

private func plain(_ editable: EditableConfig) -> [String: Any] {
    [
        "servers": editable.servers.map { ["name": $0] },
        "defaults": editable.defaults.mapValues(plain),
        "focus": editable.focus.mapValues(plain),
        "rules": editable.rules.map { $0.mapValues(plain) },
    ]
}

@Suite struct EditingParity {
    @Test(arguments: Fixture.load("editing"))
    func edit(_ fixture: Fixture) throws {
        let input = fixture.input
        let text = input["text"] as! String
        switch input["op"] as! String {
        case "read":
            let got = NSDictionary(dictionary: plain(try readEditable(text)))
            #expect(got == NSDictionary(dictionary: fixture.expected as! [String: Any]), "\(got)")
        case "apply":
            let edit = payload(input["payload"] as! [String: Any])
            if let message = fixture.message {
                do {
                    let result = try applyEdit(text, payload: edit, sounds: fixtureSounds)
                    Issue.record("accepted, want \(message):\n\(result)")
                } catch let error as ConfigError {
                    #expect(error.description == message)
                }
                return
            }
            let got = try applyEdit(text, payload: edit, sounds: fixtureSounds)
            #expect(got == fixture.expected as! String, "\(got.debugDescription)\nwant \((fixture.expected as! String).debugDescription)")
        case "roundtrip":
            let got = try applyEdit(text, payload: EditPayload(state: try readEditable(text)), sounds: fixtureSounds)
            #expect(got == fixture.expected as! String, "\(got.debugDescription)\nwant \((fixture.expected as! String).debugDescription)")
        case "replace":
            let got = try replaceSound(text, old: input["old"] as! String, new: input["new"] as! String)
            #expect(got == fixture.expected as! String, "\(got.debugDescription)\nwant \((fixture.expected as! String).debugDescription)")
        default:
            Issue.record("unknown op")
        }
    }
}
