import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum AudioDeviceManager {
    static func devices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard let name = stringProperty(id, kAudioObjectPropertyName), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let input = streamCount(id, scope: kAudioDevicePropertyScopeInput) > 0
            let output = streamCount(id, scope: kAudioDevicePropertyScopeOutput) > 0
            guard input || output else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, hasInput: input, hasOutput: output)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func configureInput(_ uid: String?, for engine: AVAudioEngine) throws {
        guard let uid, let device = devices().first(where: { $0.uid == uid && $0.hasInput }), let unit = engine.inputNode.audioUnit else { return }
        var id = AudioDeviceID(device.id)
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw AudioDeviceError.cannotSelect(status) }
    }

    static func configureOutput(_ uid: String?, for engine: AVAudioEngine) throws {
        guard let uid, let device = devices().first(where: { $0.uid == uid && $0.hasOutput }), let unit = engine.outputNode.audioUnit else { return }
        var id = AudioDeviceID(device.id)
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw AudioDeviceError.cannotSelect(status) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeUnretainedValue() else { return nil }
        return string as String
    }

    private static func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

enum AudioDeviceError: LocalizedError {
    case cannotSelect(OSStatus)
    var errorDescription: String? {
        switch self { case .cannotSelect(let status): "Could not select audio device (\(status))." }
    }
}
