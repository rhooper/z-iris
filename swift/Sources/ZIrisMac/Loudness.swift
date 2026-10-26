import AVFoundation
import ZIrisCore

// Measuring and rewriting sounds with AVAudioFile, in place of sox's stat
// and vol effects.

/// Peak and RMS as sox's stat effect reports them: over every sample of every
/// channel, the peak being the largest sample (not the largest magnitude).
public func soundLevels(_ url: URL) -> (peak: Double, rms: Double)? {
    guard let file = try? AVAudioFile(forReading: url),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)
    else { return nil }
    var peak = -Double.infinity
    var squares = 0.0
    var count = 0
    do {
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
                for sample in samples {
                    let value = Double(sample)
                    peak = max(peak, value)
                    squares += value * value
                }
                count += samples.count
            }
        }
    } catch {
        return nil
    }
    guard count > 0 else { return nil }
    return (peak, (squares / Double(count)).squareRoot())
}

public struct LoudnessError: Error, CustomStringConvertible {
    public var description: String
}

/// Write source to destination as a 16-bit WAV at the target loudness;
/// returns the gain used.
@discardableResult
public func writeNormalized(_ source: URL, to destination: URL) throws -> Double {
    let gain = soundLevels(source).map { gainFor(peak: $0.peak, rms: $0.rms) } ?? 1
    do {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else {
            throw LoudnessError(description: "no buffer")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    channels[channel][frame] = max(-1, min(1, channels[channel][frame] * Float(gain)))
                }
            }
            try output.write(from: buffer)
        }
    } catch let error as LoudnessError {
        throw error
    } catch {
        throw LoudnessError(description: "could not convert \(source.lastPathComponent): \(error.localizedDescription)")
    }
    return gain
}

/// Replace a sound with a normalized WAV. Returns the file now and whether it
/// changed. The original is copied into originals (when given) first; a file
/// already at the target loudness is left alone.
public func normalizeFile(_ url: URL, originals: URL?) throws -> (URL, Bool) {
    guard let measured = soundLevels(url) else { return (url, false) }
    let gain = gainFor(peak: measured.peak, rms: measured.rms)
    if url.pathExtension.lowercased() == "wav", withinTolerance(gain) {
        return (url, false)
    }
    let files = FileManager.default
    let temporary = url.deletingLastPathComponent()
        .appendingPathComponent(".normalize-\(url.deletingPathExtension().lastPathComponent).wav")
    defer { try? files.removeItem(at: temporary) }
    try writeNormalized(url, to: temporary)
    if let originals {
        try files.createDirectory(at: originals, withIntermediateDirectories: true)
        let copy = originals.appendingPathComponent(url.lastPathComponent)
        try? files.removeItem(at: copy)
        try files.copyItem(at: url, to: copy)
    }
    let final = url.deletingPathExtension().appendingPathExtension("wav")
    if final != url {
        try files.removeItem(at: url)
    }
    _ = try files.replaceItemAt(final, withItemAt: temporary)
    return (final, true)
}

/// Normalize every sound in a folder. Returns (before, after) for changed ones.
public func normalizeDirectory(_ directory: URL, keepOriginals: Bool = true) -> [(URL, URL)] {
    let files = FileManager.default
    let originals = keepOriginals ? directory.appendingPathComponent("originals") : nil
    var changed: [(URL, URL)] = []
    let names = ((try? files.contentsOfDirectory(atPath: directory.path)) ?? []).sorted(by: pythonOrder)
    for name in names {
        let url = directory.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              soundSuffixes.contains("." + url.pathExtension.lowercased()),
              let (final, didChange) = try? normalizeFile(url, originals: originals), didChange
        else { continue }
        changed.append((url, final))
    }
    return changed
}
