import Foundation

// The sound library: bundled tones plus the user's own files (sounds.py).

public let soundSuffixes = [".wav", ".aiff", ".aif", ".flac", ".mp3", ".ogg", ".caf"]

/// Sound names to files. User files win over bundled tones; "synth" stays an
/// alias for "chime", the name old configs used.
public func soundLibrary(builtin: URL, user: URL?) -> [String: String] {
    let files = FileManager.default
    var sounds: [String: String] = [:]
    for name in (try? files.contentsOfDirectory(atPath: builtin.path)) ?? [] where name.hasSuffix(".wav") {
        sounds[String(name.dropLast(4))] = builtin.appendingPathComponent(name).path
    }
    sounds["synth"] = sounds["chime"]
    var isDirectory: ObjCBool = false
    if let user, files.fileExists(atPath: user.path, isDirectory: &isDirectory), isDirectory.boolValue {
        for name in ((try? files.contentsOfDirectory(atPath: user.path)) ?? []).sorted(by: pythonOrder) {
            let url = user.appendingPathComponent(name)
            let suffix = "." + url.pathExtension.lowercased()
            var isDir: ObjCBool = false
            guard !name.hasPrefix("."), url.pathExtension != "", soundSuffixes.contains(suffix),
                  files.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue
            else { continue }
            sounds[url.deletingPathExtension().lastPathComponent] = url.path
        }
    }
    return sounds
}
