import Foundation
import Testing
import ZIrisCore

/// Where ICU and Python's re (3.13) differ and translation can't help:
/// ICU folds case fully, so ß matches SS; Python's \B never matches "".
private let knownDifferences: Set<[String]> = [["straße", "STRASSE"], ["\\B", ""]]

@Suite struct RegexParity {
    @Test(arguments: Fixture.load("regex"))
    func regex(_ fixture: Fixture) {
        let pattern = fixture.input["pattern"] as! String
        if fixture.error != nil {
            #expect(throws: PyRegex.Error.self) { try PyRegex(pattern) }
            return
        }
        let regex: PyRegex
        do {
            regex = try PyRegex(pattern)
        } catch {
            Issue.record("Swift refused \(pattern): \(error)")
            return
        }
        let subjects = fixture.input["subjects"] as! [String]
        let expected = fixture.expected as! [[String: Any]]
        for (subject, want) in zip(subjects, expected) where !knownDifferences.contains([pattern, subject]) {
            let found = regex.search(subject).map { (subject as NSString).substring(with: $0) }
            #expect(found == want["search"] as? String, "search \(subject.debugDescription)")
            #expect(regex.fullMatch(subject) == want["fullmatch"] as! Bool, "fullmatch \(subject.debugDescription)")
        }
    }
}
