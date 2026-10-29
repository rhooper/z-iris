import Foundation
import SwiftUI
import Testing
import ViewInspector
import ZIrisCore
import ZulipKit
@testable import ZIrisMac

// The editor's controls, inspected without a window: ViewInspector reads the
// view tree and drives bindings, so nothing is put on screen or takes focus.

@MainActor
private func model(servers: [String] = ["w"]) throws -> EditorModel {
    let config = try parseConfig("[[server]]\nname = \"w\"\nzuliprc = \"/x\"\n", sounds: ["chime": "/c.wav"])
    // A config file that does not exist: the save an edit schedules fails harmlessly.
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-\(UUID())/config.toml").path
    let model = EditorModel(configPath: path, settings: Settings(config), builtinSounds: URL(fileURLWithPath: "/"),
                            player: nil, flasher: nil)
    model.servers = servers
    model.users = ["w": [ServerUser(id: 1, fullName: "Ada Lovelace", email: "ada@x"),
                         ServerUser(id: 3, fullName: "Rob Roy", email: "rob@x")]]
    return model
}

/// Fields a binding can edit, as the editor's rule state.
@MainActor
private final class Fields {
    var value: [String: TOMLValue]
    init(_ value: [String: TOMLValue]) { self.value = value }
    var binding: Binding<[String: TOMLValue]> { Binding(get: { self.value }, set: { self.value = $0 }) }
    func key(_ name: String) -> Binding<TOMLValue?> {
        Binding(get: { self.value[name] }, set: { self.value[name] = $0 })
    }
}

@MainActor
@Suite struct PersonTokensTests {
    @Test func theMenuAddsPeopleByID() throws {
        let model = try model()
        let fields = Fields(["sender": .array([.integer(1)])])
        let view = PersonTokens(model: model, people: fields.key("sender"), servers: ["w"], footer: "")
        // Ada is listed already, so the menu offers only Rob.
        let menu = try view.inspect().find(ViewType.Menu.self)
        #expect(throws: (any Error).self) { try menu.find(button: "Ada Lovelace · ada@x") }
        try menu.find(button: "Rob Roy · rob@x").tap()
        #expect(fields.value["sender"] == .array([.integer(1), .integer(3)]))
    }

    @Test func knownPeopleByNameUnknownOnesFlagged() throws {
        let model = try model()
        let fields = Fields(["sender": .array([.integer(1), .integer(999_999), .string("Old Name")])])
        let view = try PersonTokens(model: model, people: fields.key("sender"), servers: ["w"], footer: "").inspect()
        #expect(try view.find(text: "Ada Lovelace").pathToRoot.isEmpty == false)
        let flagged = try view.findAll(ViewType.Label.self).map { try $0.title().text().string() }
        #expect(flagged == ["User 999999", "Old Name"])
    }

    @Test func removingAPerson() throws {
        let model = try model()
        let fields = Fields(["sender": .array([.integer(1), .integer(3)])])
        let view = try PersonTokens(model: model, people: fields.key("sender"), servers: ["w"], footer: "").inspect()
        try view.findAll(ViewType.Button.self).first { (try? $0.labelView().image().actualImage().name()) == "xmark.circle.fill" }!.tap()
        #expect(fields.value["sender"] == .array([.integer(3)]))
        try PersonTokens(model: model, people: fields.key("sender"), servers: ["w"], footer: "").inspect()
            .findAll(ViewType.Button.self).first { (try? $0.labelView().image().actualImage().name()) == "xmark.circle.fill" }!.tap()
        #expect(fields.value["sender"] == nil)
    }

    @Test func severalServersNeedTheRulesServerFirst() throws {
        let model = try model(servers: ["w", "v"])
        let fields = Fields([:])
        let view = try PersonTokens(model: model, people: fields.key("sender"), servers: ["w", "v"], footer: "").inspect()
        #expect(throws: (any Error).self) { try view.find(ViewType.TextField.self) }
        _ = try view.find(text: "Choose the rule's server to pick people.")
    }
}

@MainActor
@Suite struct ConditionFieldsTests {
    private func people(_ match: String) throws -> Int {
        let fields = Fields(["match": .string(match)])
        return try ConditionFields(model: try model(), fields: fields.binding, servers: ["w"]).inspect()
            .findAll(PersonTokens.self).count
    }

    @Test func peopleFieldsByKind() throws {
        #expect(try people("sender") == 1)
        #expect(try people("dm") == 1)  // From
        #expect(try people("group_dm") == 2)  // From and With
        #expect(try people("keyword") == 0)
    }
}

@MainActor
@Suite struct ExceptionsSectionTests {
    @Test func addAndRemoveExceptions() throws {
        let model = try model()
        let fields = Fields(["match": .string("keyword")])
        try ExceptionsSection(model: model, fields: fields.binding).inspect().find(button: "Add Exception").tap()
        #expect(fields.value["except"] == .array([.table([("match", .string("channel"))])]))

        // Change its kind: the exception's own fields, written in config order.
        let view = try ExceptionsSection(model: model, fields: fields.binding).inspect()
        try view.find(ViewType.Picker.self).select(value: "sender")
        #expect(fields.value["except"] == .array([.table([("match", .string("sender"))])]))
        let shown = try ExceptionsSection(model: model, fields: fields.binding).inspect()
        #expect(shown.findAll(PersonTokens.self).count == 1)
        try shown.find(ViewType.Menu.self).find(button: "Rob Roy · rob@x").tap()
        #expect(fields.value["except"] == .array([.table([("match", .string("sender")), ("sender", .array([.integer(3)]))])]))

        try ExceptionsSection(model: model, fields: fields.binding).inspect()
            .findAll(ViewType.Button.self).first { (try? $0.labelView().image().actualImage().name()) == "minus.circle.fill" }!.tap()
        #expect(fields.value["except"] == nil)
    }

    @Test func theSidebarLabelNamesExceptions() throws {
        let model = try model()
        let rule = EditableRule(["match": .string("keyword"), "keyword": .string("deploy"),
                                 "except": .array([.table([("match", .string("sender")), ("sender", .array([.integer(3)]))])])])
        #expect(model.label(rule) == "Keyword /deploy/, except Sender Rob Roy")
    }
}
