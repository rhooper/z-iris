import AVFoundation
import Foundation
import Testing
import ZIrisCore
@testable import ZIrisMac

private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-loudness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A 16-bit WAV whose channel c holds amplitude[c] * sin(2 pi 440 t).
private func sine(_ url: URL, amplitudes: [Float], seconds: Double = 0.5) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: AVAudioChannelCount(amplitudes.count))!
    let frames = AVAudioFrameCount(44100 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for (channel, amplitude) in amplitudes.enumerated() {
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![channel][frame] = amplitude * sin(2 * .pi * 440 * Float(frame) / 44100)
        }
    }
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: amplitudes.count,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

/// sox's own stat, when sox is installed, as the reference.
private func soxStat(_ url: URL) -> (peak: Double, rms: Double)? {
    guard let sox = ["/opt/homebrew/bin/sox", "/usr/local/bin/sox"].first(where: FileManager.default.isExecutableFile) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sox)
    process.arguments = [url.path, "-n", "stat"]
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    func value(_ label: String) -> Double? {
        text.components(separatedBy: "\n").first { $0.hasPrefix(label) }
            .flatMap { $0.split(separator: ":").last.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
    }
    guard let peak = value("Maximum amplitude"), let rms = value("RMS     amplitude") else { return nil }
    return (peak, rms)
}

@Suite struct LoudnessTests {
    @Test func levelsMatchSoxStatOverAllChannels() throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("stereo.wav")
        try sine(url, amplitudes: [0.9, 0.3])
        let levels = try #require(soundLevels(url))
        #expect(abs(levels.peak - 0.9) < 0.001)
        #expect(abs(levels.rms - ((0.9 * 0.9 / 2 + 0.3 * 0.3 / 2) / 2).squareRoot()) < 0.001)  // 0.474, as sox
        if let sox = soxStat(url) {
            #expect(abs(levels.peak - sox.peak) < 0.0001)
            #expect(abs(levels.rms - sox.rms) < 0.0001)
        }
    }

    @Test func everyBundledToneMeasuresAsSoxDoes() throws {
        let tones = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/sounds").standardized
        let names = try FileManager.default.contentsOfDirectory(atPath: tones.path).filter { $0.hasSuffix(".wav") }
        #expect(names.count > 40)
        for name in names {
            let url = tones.appendingPathComponent(name)
            guard let sox = soxStat(url) else { return }  // no sox here: nothing to compare with
            let levels = try #require(soundLevels(url))
            #expect(abs(levels.peak - sox.peak) < 0.0001, "\(name) peak")
            #expect(abs(levels.rms - sox.rms) < 0.0001, "\(name) rms")
        }
    }

    @Test func gain() {
        #expect(gainFor(peak: 0, rms: 0.1) == 1)
        #expect(gainFor(peak: 0.5, rms: 0.1) == 2)  // the peak limits it
        #expect(abs(gainFor(peak: 0.25, rms: 0.19) - 2) < 1e-12)  // the target limits it
        #expect(gainFor(peak: 1, rms: 0.19) == 1)  // the peak would clip
        #expect(withinTolerance(1.05) && !withinTolerance(1.1))
    }

    @Test func normalizingReachesTheTargetAndTwiceChangesNothing() throws {
        let folder = try directory()
        let quiet = folder.appendingPathComponent("quiet.wav")
        try sine(quiet, amplitudes: [0.1])
        let (final, changed) = try normalizeFile(quiet, originals: folder.appendingPathComponent("originals"))
        #expect(changed && final == quiet)
        let levels = try #require(soundLevels(final))
        #expect(abs(levels.rms - targetRMS) < 0.005)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("originals/quiet.wav").path))
        #expect(try normalizeFile(final, originals: nil).1 == false)
    }

    @Test func aNonWavBecomesAWav() throws {
        let folder = try directory()
        let source = folder.appendingPathComponent("tone.caf")
        try sine(source, amplitudes: [0.38 * 2.squareRoot()].map(Float.init))
        let changed = normalizeDirectory(folder, keepOriginals: false)
        #expect(changed.count == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tone.wav").path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
}
