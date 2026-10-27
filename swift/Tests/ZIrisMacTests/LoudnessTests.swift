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

@Suite struct LoudnessTests {
    @Test func aFileMeasuresAsItsSamplesDo() throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("stereo.wav")
        try sine(url, amplitudes: [0.9, -0.3])
        let measured = try #require(soundMeasure(url))
        #expect(abs(measured.peak - 0.9) < 0.001)
        // Both channels count, as BS.1770 sums them: louder than the left alone.
        let left = folder.appendingPathComponent("left.wav")
        try sine(left, amplitudes: [0.9])
        #expect(measured.loudness > (try #require(soundMeasure(left))).loudness)
    }

    @Test func everyBundledSoundIsAtTheTargetLoudnessOrPeakLimited() throws {
        let tones = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/sounds").standardized
        let names = try FileManager.default.contentsOfDirectory(atPath: tones.path).filter { $0.hasSuffix(".wav") }
        #expect(names.count > 40)
        for name in names {
            let measured = try #require(soundMeasure(tones.appendingPathComponent(name)))
            let gain = gainFor(peak: measured.peak, loudness: measured.loudness)
            #expect(withinTolerance(gain) || measured.peak > 0.97, "\(name): \(measured)")
        }
    }

    @Test func normalizingReachesTheTargetAndTwiceChangesNothing() throws {
        let folder = try directory()
        let quiet = folder.appendingPathComponent("quiet.wav")
        try sine(quiet, amplitudes: [0.1])
        let (final, changed) = try normalizeFile(quiet, originals: folder.appendingPathComponent("originals"))
        #expect(changed && final == quiet)
        let measured = try #require(soundMeasure(final))
        #expect(abs(measured.loudness - targetLoudness) < 0.2)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("originals/quiet.wav").path))
        #expect(try normalizeFile(final, originals: nil).1 == false)
    }

    @Test func aNonWavBecomesAWav() throws {
        let folder = try directory()
        let source = folder.appendingPathComponent("tone.caf")
        try sine(source, amplitudes: [0.1])
        let changed = normalizeDirectory(folder, keepOriginals: false)
        #expect(changed.count == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tone.wav").path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
}
