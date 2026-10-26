// Spike (Swift port, phase 3b), 2026-10-26: is AVAudioEngine heard through
// Audio Hijack, on the default output and pinned to a named device?
// Usage: swift scripts/claude/spikes/audio_engine.swift --list
//        swift scripts/claude/spikes/audio_engine.swift FILE [DEVICE NAME]

import AVFoundation
import CoreAudio

func outputDevices() -> [(id: AudioDeviceID, name: String)] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    return ids.compactMap { id in
        var streams = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize)
        guard streamSize > 0 else { return nil }
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
        return (id, name?.takeRetainedValue() as String? ?? "?")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--list" || arguments.isEmpty {
    for device in outputDevices() { print(device.id, device.name) }
    exit(0)
}

let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[0]))
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)

if arguments.count > 1 {
    let wanted = arguments[1...].joined(separator: " ")
    guard let device = outputDevices().first(where: { $0.name == wanted }) else {
        print("no output device named \(wanted)")
        exit(1)
    }
    var id = device.id
    let status = AudioUnitSetProperty(
        engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &id, UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    print("pinned to \(wanted) (\(device.id)) status \(status)")
} else {
    print("default output")
}

// A short silent lead-in: an output asleep after a quiet spell can swallow the attack.
let lead = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate * 0.12))!
lead.frameLength = lead.frameCapacity
try engine.start()
let done = DispatchSemaphore(value: 0)
player.scheduleBuffer(lead)
player.scheduleFile(file, at: nil) { done.signal() }
player.play()
done.wait()
Thread.sleep(forTimeInterval: 0.3)
engine.stop()
print("played \(arguments[0])")
