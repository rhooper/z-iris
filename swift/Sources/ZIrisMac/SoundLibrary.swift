import AVFoundation
import ZIrisCore

// Adding and removing the user's own sounds (sounds.py). An added sound is
// stored normalized as a WAV, with the file as given kept in originals/.

public let maxSoundBytes = 10_000_000
private let reservedNames: Set<String> = ["none", "synth"]

public struct SoundError: Error, Equatable, CustomStringConvertible {
    public var description: String
}

/// The names of the user's own sounds.
public func userSoundNames(_ directory: URL) -> [String] {
    let files = FileManager.default
    return ((try? files.contentsOfDirectory(atPath: directory.path)) ?? []).compactMap { name in
        let url = directory.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard !name.hasPrefix("."), soundSuffixes.contains("." + url.pathExtension.lowercased()),
              files.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }.sorted(by: pythonOrder)
}

/// Store a sound and return its name.
public func addSound(_ directory: URL, builtin: URL, filename: String, data: Data) throws(SoundError) -> String {
    if data.count > maxSoundBytes {
        throw SoundError(description: "file is too large (10 MB limit)")
    }
    if filename.contains("/") || filename.contains("\\") || filename.hasPrefix(".") {
        throw SoundError(description: "bad file name")
    }
    let file = URL(fileURLWithPath: filename)
    let suffix = file.pathExtension.isEmpty ? "" : "." + file.pathExtension.lowercased()
    guard soundSuffixes.contains(suffix) else {
        throw SoundError(description: "file type must be one of \(soundSuffixes.joined(separator: ", "))")
    }
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _.-")
    let name = String(file.deletingPathExtension().lastPathComponent.filter(allowed.contains))
        .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    if name.isEmpty || reservedNames.contains(name.lowercased()) {
        throw SoundError(description: "bad sound name")
    }
    let taken = Set(soundLibrary(builtin: builtin, user: directory).keys.map { $0.lowercased() })
    if taken.contains(name.lowercased()) {
        throw SoundError(description: "a sound named \"\(name)\" already exists; rename the file")
    }

    let files = FileManager.default
    let upload = directory.appendingPathComponent(".upload-\(UUID().uuidString)\(suffix)")
    let converted = directory.appendingPathComponent(".convert-\(name).wav")
    defer {
        try? files.removeItem(at: upload)
        try? files.removeItem(at: converted)
    }
    do {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: upload)
    } catch {
        throw SoundError(description: "cannot store the file: \(error.localizedDescription)")
    }
    guard (try? AVAudioFile(forReading: upload)) != nil else {
        throw SoundError(description: "this file cannot be played")
    }
    do {
        try writeNormalized(upload, to: converted)
        let originals = directory.appendingPathComponent("originals")
        try files.createDirectory(at: originals, withIntermediateDirectories: true)
        let original = originals.appendingPathComponent(name + suffix)
        try? files.removeItem(at: original)
        try files.copyItem(at: upload, to: original)
        _ = try files.replaceItemAt(directory.appendingPathComponent(name + ".wav"), withItemAt: converted)
    } catch {
        throw SoundError(description: "\(error)")
    }
    return name
}

/// Delete one of the user's own sounds and its saved original.
public func deleteSound(_ directory: URL, builtin: URL, name: String) throws(SoundError) {
    guard userSoundNames(directory).contains(name) else {
        if soundLibrary(builtin: builtin, user: nil)[name] != nil {
            throw SoundError(description: "\"\(name)\" is a bundled tone and cannot be deleted")
        }
        throw SoundError(description: "no sound of yours is named \"\(name)\"")
    }
    let files = FileManager.default
    for folder in [directory, directory.appendingPathComponent("originals")] {
        for entry in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let url = folder.appendingPathComponent(entry)
            let inOriginals = folder != directory
            guard url.deletingPathExtension().lastPathComponent == name,
                  inOriginals || soundSuffixes.contains("." + url.pathExtension.lowercased())
            else { continue }
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                try? files.removeItem(at: url)
            }
        }
    }
}
