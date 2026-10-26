import CryptoKit
import Foundation

// The tiles of a group DM's picture (comms.py): macOS draws nothing for a
// group, so z-iris draws the sender (avatar, else initials) and up to three
// others' initials. Drawing is in ZIrisMac.

public let tilePalette = ["#e5484d", "#f76b15", "#ffc53d", "#30a46c", "#12a594", "#0090ff", "#6e56cf", "#d6409f"]

public enum GroupTile: Sendable, Equatable {
    case avatar(String)
    case initials(String, color: String)
}

private func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    // Python's str.isalnum: a letter (L*) or anything with a numeric type.
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
    default: return scalar.properties.numericType != nil
    }
}

func initials(_ name: String) -> String {
    let words = name.replacingOccurrences(of: "(", with: " ").pythonWords
        .filter { $0.unicodeScalars.first.map(isAlphanumeric) ?? false }
    let letters = words.prefix(2).map { String($0.unicodeScalars.first!).uppercased() }.joined()
    return letters.isEmpty ? "?" : letters
}

func tileColor(_ handle: String) -> String {
    // int(sha1, 16) % 8 is the last byte's value mod 8.
    let digest = Insecure.SHA1.hash(data: Data(handle.utf8))
    return tilePalette[Int(Array(digest).last! % 8)]
}

/// Up to four tiles: the sender (avatar, else initials), then others' initials.
public func groupTiles(_ sender: Sender) -> [GroupTile] {
    let first: GroupTile = sender.avatar.map { .avatar($0) } ?? .initials(initials(sender.name), color: tileColor(sender.handle))
    let others = sender.members.filter { $0.handle != sender.handle }
        .map { GroupTile.initials(initials($0.name), color: tileColor($0.handle)) }
    return Array(([first] + others).prefix(4))
}

/// The picture's cache name: comms.py hashes repr() of the tile tuples.
public func groupPictureName(_ tiles: [GroupTile]) -> String {
    let repr = "[" + tiles.map { tile -> String in
        switch tile {
        case .avatar(let path): "(\(pythonRepr("avatar")), \(pythonRepr(path)))"
        case let .initials(text, color): "(\(pythonRepr("initials")), \(pythonRepr(text)), \(pythonRepr(color)))"
        }
    }.joined(separator: ", ") + "]"
    let digest = Insecure.SHA1.hash(data: Data(repr.utf8)).map { String(format: "%02x", $0) }.joined()
    return "group-\(digest.prefix(16)).png"
}
