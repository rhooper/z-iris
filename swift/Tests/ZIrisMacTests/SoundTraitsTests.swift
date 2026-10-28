import AVFoundation
import Foundation
import Testing
import ZIrisCore
@testable import ZIrisMac

private func tone(_ hz: Float, seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("z-iris-traits-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let frames = AVAudioFrameCount(44100 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for n in 0..<Int(frames) {
        buffer.floatChannelData![0][n] = 0.5 * sin(2 * .pi * hz * Float(n) / 44100)
    }
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    return url
}

@Suite struct SoundTraitsTests {
    @Test func lengthAndCentroid() throws {
        let low = try #require(soundTraits(try tone(300, seconds: 0.5)))
        #expect(abs(low.seconds - 0.5) < 0.01)
        #expect(abs(low.centroid - 300) < 40)
        let high = try #require(soundTraits(try tone(3000, seconds: 0.2)))
        #expect(abs(high.centroid - 3000) < 100)
        #expect(SoundPitch(centroid: low.centroid) == .low && SoundPitch(centroid: high.centroid) == .high)
    }
}
