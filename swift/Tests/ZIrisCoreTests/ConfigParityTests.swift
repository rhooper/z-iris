import Foundation
import Testing
@testable import ZIrisCore

/// The bundled sound names at the fixed paths gen_fixtures.py uses.
let fixtureSounds: [String: String] = {
    let config = Fixture.load("config").first { $0.name == "sound_unknown" }!
    let message = config.message!
    let names = message[message.range(of: "one of ")!.upperBound...].components(separatedBy: ", ")
    var sounds = Dictionary(uniqueKeysWithValues: names.map { ($0, "/sounds/\($0).wav") })
    sounds["synth"] = sounds["chime"]
    return sounds
}()

private let home = NSHomeDirectory()

private func unhome(_ text: String) -> String {
    text.hasPrefix(home) ? "~HOME" + text.dropFirst(home.count) : text
}

private func json(_ value: Any?) -> Any { value ?? NSNull() }

private func json(_ behaviour: Behaviour) -> [String: Any] {
    behaviour.mapValues { value -> Any in
        switch value {
        case .text(let text): text
        case .number(let number): number
        case .integer(let number): number
        case .flag(let flag): flag
        }
    }
}

private func json(_ config: Config) -> [String: Any] {
    [
        "servers": config.servers.map { ["name": $0.name, "zuliprc": unhome($0.zuliprc), "volume": $0.volume] },
        "sound": unhome(config.sound), "volume": config.volume,
        "notify_channel_messages": config.notifyChannelMessages, "player": config.player,
        "notifier": config.notifier, "external_images": config.externalImages,
        "master_volume": config.masterVolume,
        "rules": config.rules.map { rule -> [String: Any] in
            [
                "description": json(rule.description), "kind": rule.kind.rawValue,
                "channels": rule.channels, "pattern": json(rule.pattern?.source),
                "server": json(rule.server), "sound": json(rule.sound), "volume": json(rule.volume),
                "banner": json(rule.banner), "priority": rule.priority, "index": rule.index,
                "enabled": rule.enabled, "behaviour": json(rule.behaviour), "label": rule.label,
            ]
        },
        "behaviour": json(config.behaviour),
        "focus": [
            "mode": config.focus.mode, "quiet_mode": config.focus.quietMode,
            "quiet_hours": config.focus.quietHours.map { [$0.start, $0.end] },
        ],
    ]
}

/// Error text from the TOML parser and the regex engine differs between the
/// versions; everything up to it must match.
private func comparable(_ message: String) -> String {
    for marker in ["invalid TOML: ", ": bad regular expression: ", ": bad channel pattern "] {
        if let range = message.range(of: marker) {
            return String(message[..<range.upperBound])
        }
    }
    return message
}

@Suite struct ConfigParity {
    @Test(arguments: Fixture.load("config"))
    func parse(_ fixture: Fixture) {
        let text = fixture.input["toml"] as! String
        if let expected = fixture.message {
            #expect(throws: ConfigError.self) { try parseConfig(text, sounds: fixtureSounds) }
            do {
                _ = try parseConfig(text, sounds: fixtureSounds)
            } catch {
                #expect(comparable(error.description) == comparable(expected))
            }
            return
        }
        do {
            let config = try parseConfig(text, sounds: fixtureSounds)
            let got = NSDictionary(dictionary: json(config))
            let want = NSDictionary(dictionary: fixture.expected as! [String: Any])
            #expect(got == want, "\(got)\nwant \(want)")
        } catch {
            Issue.record("Swift refused: \(error)")
        }
    }

    @Test(arguments: Fixture.load("action"))
    func action(_ fixture: Fixture) throws {
        let config = try parseConfig(fixture.input["toml"] as! String, sounds: fixtureSounds)
        let rule = (fixture.input["rule"] as? Int).map { config.rules[$0] }
        let action = resolveAction(config, server: fixture.input["server"] as! String, rule: rule)
        let got: [String: Any] = [
            "sound": unhome(action.sound), "volume": action.volume, "banner": action.banner,
            "rule": json(action.rule), "flash": action.flash, "flash_color": action.flashColor,
            "flash_seconds": action.flashSeconds, "repeat": action.repeat,
            "repeat_every": action.repeatEvery, "repeat_boost": action.repeatBoost,
            "min_gap": action.minGap, "batch_window": action.batchWindow, "sticky": action.sticky,
            "stay": action.stay, "rule_index": json(action.ruleIndex),
        ]
        var want = fixture.expected as! [String: Any]
        want["sound"] = unhome(want["sound"] as! String)
        #expect(NSDictionary(dictionary: got) == NSDictionary(dictionary: want))
    }

    @Test(arguments: Fixture.load("pick"))
    func pick(_ fixture: Fixture) throws {
        let config = try parseConfig(fixture.input["toml"] as! String, sounds: fixtureSounds)
        let message = Message(fixture: fixture.input["message"] as! [String: Any])
        #expect(pickRule(config.rules, message)?.index == fixture.expected as? Int)
    }
}
