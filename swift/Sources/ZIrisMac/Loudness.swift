import Accelerate
import AVFoundation
import ZIrisCore

// Measuring and rewriting sounds with AVAudioFile, in place of sox's stat
// and vol effects.

/// A sound's largest sample magnitude and its momentary loudness (LUFS).
public func soundMeasure(_ url: URL) -> (peak: Double, loudness: Double)? {
    guard let file = try? AVAudioFile(forReading: url),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)
    else { return nil }
    var channels = [[Double]](repeating: [], count: Int(file.processingFormat.channelCount))
    var peak = 0.0
    do {
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            for channel in channels.indices {
                for sample in UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)) {
                    let value = Double(sample)
                    peak = max(peak, abs(value))
                    channels[channel].append(value)
                }
            }
        }
    } catch {
        return nil
    }
    guard channels.contains(where: { !$0.isEmpty }) else { return nil }
    return (peak, momentaryLoudness(channels, rate: file.processingFormat.sampleRate))
}

public struct LoudnessError: Error, CustomStringConvertible {
    public var description: String
}

/// Write source to destination as a 16-bit WAV at the target loudness;
/// returns the gain used.
@discardableResult
public func writeNormalized(_ source: URL, to destination: URL) throws -> Double {
    let gain = soundMeasure(source).map { gainFor(peak: $0.peak, loudness: $0.loudness) } ?? 1
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
    guard let measured = soundMeasure(url) else { return (url, false) }
    let gain = gainFor(peak: measured.peak, loudness: measured.loudness)
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

/// A sound's length in seconds and its spectral centroid in Hz (the
/// power-weighted mean frequency over the whole sound), for the sound browser.
public func soundTraits(_ url: URL) -> (seconds: Double, centroid: Double)? {
    guard let file = try? AVAudioFile(forReading: url),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { return nil }
    do { try file.read(into: buffer) } catch { return nil }
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
    let rate = file.processingFormat.sampleRate
    let length = Int(buffer.frameLength)
    var mono = [Float](repeating: 0, count: length)
    for channel in 0..<Int(file.processingFormat.channelCount) {
        vDSP.add(mono, UnsafeBufferPointer(start: data[channel], count: length), result: &mono)
    }
    let size = 4096
    guard let dft = try? vDSP.DiscreteFourierTransform(
        count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self
    ) else { return nil }
    let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    let zeros = [Float](repeating: 0, count: size)
    var weighted = 0.0, total = 0.0
    var start = 0
    repeat {
        var frame = [Float](repeating: 0, count: size)
        let count = min(size, length - start)
        frame.replaceSubrange(0..<count, with: mono[start..<start + count])
        let (real, imaginary) = dft.transform(real: vDSP.multiply(frame, window), imaginary: zeros)
        for bin in 1..<size / 2 {
            let power = Double(real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
            weighted += power * Double(bin) * rate / Double(size)
            total += power
        }
        start += size
    } while start < length
    return (Double(length) / rate, total > 0 ? weighted / total : 0)
}
