import Foundation
import Testing
@testable import ZIrisCore

private func rule(_ kind: String, _ name: String, priority: Int? = nil) -> [String: TOMLValue] {
    var fields: [String: TOMLValue] = ["match": .string(kind), "description": .string(name)]
    if let priority { fields["priority"] = .integer(priority) }
    return fields
}

private func names(_ rules: [[String: TOMLValue]], _ indices: [Int]) -> [String] {
    indices.map { if case .string(let s)? = rules[$0]["description"] { s } else { "?" } }
}

private let sample = [
    rule("channel", "ops"), rule("dm", "DM", priority: 100), rule("mention", "Me"),
    rule("channel", "errors"), rule("channel", "pagerduty", priority: 50), rule("sender", "Boss"),
    rule("conversation", "joined", priority: 5), rule("keyword", "quiet", priority: -1),
]

@Suite struct RuleOrderTests {
    @Test func sectionsFollowThePrecedenceTheEngineUses() {
        let sections = ruleSections(sample)
        #expect(sections.map(\.section) == [.first, .kind(.sender), .kind(.mention), .kind(.channel), .last,
                                            .kind(.conversation)])
        #expect(names(sample, sections[0].indices) == ["DM", "pagerduty"])  // highest priority first
        #expect(names(sample, sections[3].indices) == ["ops", "errors"])  // file order within a kind
        #expect(names(sample, sections[4].indices) == ["quiet"])
    }

    @Test func savingWritesRulesInPrecedenceOrder() throws {
        let text = "[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n"
        var b = rule("channel", "b"), c = rule("channel", "c")
        b["channel"] = .array([.string("ops")])
        c["channel"] = .array([.string("dev")])
        let out = try applyEdit(text, payload: EditPayload(rules: [b, rule("dm", "a"), c]), sounds: ["chime": "/c.wav"])
        let order = out.components(separatedBy: "description = ").dropFirst().map { String($0.prefix(3)) }
        #expect(order == ["\"b\"", "\"c\"", "\"a\""])  // channels before DMs, and b before c as given (not by name)
    }

    @Test func draggingWithinAKindReordersFileOrder() {
        let moved = movingRules(sample, in: .kind(.channel), from: [1], to: 0)
        #expect(names(moved, ruleSections(moved)[3].indices) == ["errors", "ops"])
        #expect(moved.count == sample.count)
    }

    @Test func draggingWithinFirstRenumbersPriorities() {
        let moved = movingRules(sample, in: .first, from: [1], to: 0)
        #expect(names(moved, ruleSections(moved)[0].indices) == ["pagerduty", "DM"])
        let priorities = ruleSections(moved)[0].indices.map { moved[$0]["priority"] }
        #expect(priorities == [.integer(2), .integer(1)])
    }

    @Test func pinningAndUnpinning() throws {
        let ops = sample.firstIndex { $0["description"] == .string("ops") }!
        let pinned = pinning(sample, at: ops)
        #expect(names(pinned, ruleSections(pinned)[0].indices) == ["ops", "DM", "pagerduty"])  // on top of First
        let dm = pinned.firstIndex { $0["description"] == .string("DM") }!
        let unpinned = unpinning(pinned, at: dm)
        let dmSection = try #require(ruleSections(unpinned).first { $0.section == .kind(.dm) })
        #expect(names(unpinned, dmSection.indices) == ["DM"])  // back in its kind, unpinned
        #expect(unpinned[dmSection.indices[0]]["priority"] == nil)
    }
}
