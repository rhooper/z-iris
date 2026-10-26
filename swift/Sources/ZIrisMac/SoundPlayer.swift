import AVFoundation
import CoreAudio
import ZIrisCore

// Sounds through AVAudioEngine, in place of `play FILE vol GAIN`: the same
// linear gain, sounds may overlap, and a short silent lead-in wakes an output
// that is asleep (as `attention` does). docs/swift-macos-spikes.md, b.

public final class SoundPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let leadIn = 0.12

    /// - Parameter device: an output device's name to pin, or nil for the
    ///   system default.
    public init(device: String? = nil) {
        if let device, let id = Self.outputDevice(named: device) {
            var id = id
            AudioUnitSetProperty(
                engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
    }

    /// Play a file at volume percent (100 is the file as stored). Returns at
    /// once; failures are logged, never thrown.
    public func play(_ path: String, volume: Int) {
        guard volume > 0 else { return }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let player = AVAudioPlayerNode()
            try lock.withLock {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
                if !engine.isRunning {
                    try engine.start()
                }
            }
            player.volume = Float(volume) / 100
            let format = file.processingFormat
            if let lead = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * leadIn)) {
                lead.frameLength = lead.frameCapacity
                player.scheduleBuffer(lead)
            }
            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.lock.withLock {
                        player.stop()
                        self.engine.detach(player)
                    }
                }
            }
            player.play()
        } catch {
            logProblem("cannot play \(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func outputDevice(named name: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids.first { id in
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &valueSize, &value)
            return (value?.takeRetainedValue() as String?) == name
        }
    }
}
