import Foundation

// The order rules are tried in, as the editor shows it: rules pinned First
// (a positive priority), then a section per kind in the order kinds are
// tried, then any with a negative priority, then the conversation and
// reaction layers, which never compete with the rest. pickRule's own order,
// (-priority, kind rank, file position), is the same order.

public enum RuleSection: Hashable, Sendable {
    case first
    case kind(RuleKind)
    case last
}

private let layers: Set<RuleKind> = [.conversation, .reaction]

private func kind(_ rule: [String: TOMLValue]) -> RuleKind? {
    if case .string(let name)? = rule["match"] { return RuleKind(rawValue: name) }
    return rule["match"] == nil ? .mention : nil
}

private func priority(_ rule: [String: TOMLValue]) -> Int {
    switch rule["priority"] {
    case .integer(let n)?: n
    case .float(let n)?: Int(n)
    default: 0
    }
}

private func section(_ rule: [String: TOMLValue]) -> RuleSection {
    let kind = kind(rule) ?? .dm
    if layers.contains(kind) { return .kind(kind) }
    let p = priority(rule)
    return p > 0 ? .first : p < 0 ? .last : .kind(kind)
}

/// The precedence key: higher priority, then the earlier kind, then file order.
func precedence(_ rule: [String: TOMLValue], position: Int) -> (Int, Int, Int) {
    (-priority(rule), (kind(rule) ?? .dm).rankForOrder, position)
}

private extension RuleKind {
    /// The kind's place in the order; an unreadable kind sorts last.
    var rankForOrder: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

/// The rules' sections in the order they are tried, each with its rules'
/// indices in order. Empty sections are left out.
public func ruleSections(_ rules: [[String: TOMLValue]]) -> [(section: RuleSection, indices: [Int])] {
    ruleSections(rules, \.self)
}

public func ruleSections<R>(_ rules: [R], _ fields: KeyPath<R, [String: TOMLValue]>) -> [(section: RuleSection, indices: [Int])] {
    let ordered = rules.indices.sorted {
        precedence(rules[$0][keyPath: fields], position: $0) < precedence(rules[$1][keyPath: fields], position: $1)
    }
    var order: [RuleSection] = [.first]
    order += RuleKind.allCases.filter { !layers.contains($0) }.map(RuleSection.kind)
    order += [.last]
    order += RuleKind.allCases.filter(layers.contains).map(RuleSection.kind)
    return order.compactMap { wanted in
        let indices = ordered.filter { section(rules[$0][keyPath: fields]) == wanted }
        return indices.isEmpty ? nil : (wanted, indices)
    }
}

/// The rules in the order the editor shows them.
private func flattened<R>(_ rules: [R], _ sections: [(section: RuleSection, indices: [Int])]) -> [R] {
    sections.flatMap { $0.indices.map { rules[$0] } }
}

/// Drag rules within one section. In First (and Last) the priorities are
/// renumbered so the new order holds; elsewhere file order is the order.
public func movingRules(
    _ rules: [[String: TOMLValue]], in target: RuleSection, from source: IndexSet, to destination: Int
) -> [[String: TOMLValue]] {
    movingRules(rules, \.self, in: target, from: source, to: destination)
}

public func movingRules<R>(
    _ rules: [R], _ fields: WritableKeyPath<R, [String: TOMLValue]>, in target: RuleSection,
    from source: IndexSet, to destination: Int
) -> [R] {
    var sections = ruleSections(rules, fields)
    guard let at = sections.firstIndex(where: { $0.section == target }) else { return rules }
    var indices = sections[at].indices
    let moving = source.sorted().map { indices[$0] }
    let before = source.filter { $0 < destination }.count
    indices.removeAll { moving.contains($0) }
    indices.insert(contentsOf: moving, at: destination - before)
    var result = rules
    let count = indices.count
    for (place, index) in indices.enumerated() {
        switch target {
        case .first: result[index][keyPath: fields]["priority"] = .integer(count - place)
        case .last: result[index][keyPath: fields]["priority"] = .integer(-(place + 1))
        case .kind: result[index][keyPath: fields]["priority"] = nil  // file order decides
        }
    }
    sections[at].indices = indices
    return flattened(result, sections)
}

/// Pin a rule to the top of First.
public func pinning(_ rules: [[String: TOMLValue]], at index: Int) -> [[String: TOMLValue]] {
    pinning(rules, \.self, at: index)
}

public func pinning<R>(_ rules: [R], _ fields: WritableKeyPath<R, [String: TOMLValue]>, at index: Int) -> [R] {
    var result = rules
    let top = rules.map { priority($0[keyPath: fields]) }.max() ?? 0
    result[index][keyPath: fields]["priority"] = .integer(max(top, 0) + 1)
    return flattened(result, ruleSections(result, fields))
}

/// Unpin a rule: it goes back to the end of its kind's section.
public func unpinning(_ rules: [[String: TOMLValue]], at index: Int) -> [[String: TOMLValue]] {
    unpinning(rules, \.self, at: index)
}

public func unpinning<R>(_ rules: [R], _ fields: WritableKeyPath<R, [String: TOMLValue]>, at index: Int) -> [R] {
    var result = rules
    var rule = result.remove(at: index)
    rule[keyPath: fields]["priority"] = nil
    result.append(rule)
    return flattened(result, ruleSections(result, fields))
}
