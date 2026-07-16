import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// A process whose audio output can be tapped.
struct TappableApp: Identifiable, Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String

    var id: AudioObjectID { objectID }
}

/// Captures the rendered audio output of other processes through a Core Audio
/// process tap (macOS 14.2+). The tap intercepts audio before it reaches the
/// output device, so it works identically for speakers, headsets, and AirPods.
/// Requires the NSAudioCaptureUsageDescription usage string; macOS shows a
/// one-time "System Audio Recording" consent prompt on first use.
@MainActor
final class SystemAudioTap {
    enum Target {
        /// Everything except ToskVoice itself.
        case allProcesses
        /// One application (all audio processes sharing its bundle identifier).
        case app(TappableApp)
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "de.tobisk.toskvoice.system-tap")

    private(set) var tapFormat: AVAudioFormat?

    /// Lists running applications that currently have a Core Audio process
    /// object, deduplicated by bundle identifier. Helper processes (e.g.
    /// com.google.Chrome.helper) are folded into their owning app's entry;
    /// tapping matches them again by bundle-ID prefix.
    static func availableApps() -> [TappableApp] {
        guard let objectIDs = readProcessObjectList() else { return [] }
        var seen = Set<String>()
        var apps: [TappableApp] = []
        for objectID in objectIDs {
            guard let bundleID = readProcessBundleID(objectID), !bundleID.isEmpty,
                  bundleID != Bundle.main.bundleIdentifier,
                  let pid: pid_t = readProcessProperty(objectID, selector: kAudioProcessPropertyPID),
                  seen.insert(bundleID).inserted else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundleID
            apps.append(TappableApp(objectID: objectID, pid: pid, bundleID: bundleID, name: name))
        }
        // Drop helpers whose owner is present: keep "com.google.Chrome",
        // fold "com.google.Chrome.helper" into it.
        let bundleIDs = Set(apps.map(\.bundleID))
        apps.removeAll { app in
            bundleIDs.contains { other in other != app.bundleID && app.bundleID.hasPrefix(other + ".") }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var tapUUID: UUID?

    /// Creates the process tap and returns its native format. This triggers
    /// the one-time "System Audio Recording" consent prompt and fails fast if
    /// consent is denied. Call `run(onBuffer:)` afterwards to start capture.
    func prepare(target: Target) throws -> AVAudioFormat {
        stop()

        let description = try makeTapDescription(for: target)
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw SystemAudioTapError.tapCreationFailed(status)
        }
        tapID = newTapID
        tapUUID = description.uuid

        guard let format = readTapFormat(newTapID) else {
            stop()
            throw SystemAudioTapError.unknownFormat
        }
        tapFormat = format
        return format
    }

    /// Starts capturing from a prepared tap. The handler is invoked on a
    /// private queue with buffers in the tap's native format; it must copy
    /// what it keeps.
    func run(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard let format = tapFormat, let tapUUID else { throw SystemAudioTapError.unknownFormat }

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "ToskVoice Meeting Tap",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            stop()
            throw SystemAudioTapError.aggregateCreationFailed(status)
        }
        aggregateID = newAggregateID

        // The IO block runs on Core Audio's HAL thread; route it through a
        // non-actor bridge so it does not inherit main-actor isolation.
        let bridge = TapIOBridge(format: format, onBuffer: onBuffer)
        var newProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggregateID, queue, bridge.makeIOBlock())
        guard status == noErr, let procID = newProcID else {
            stop()
            throw SystemAudioTapError.ioProcFailed(status)
        }
        ioProcID = procID

        status = AudioDeviceStart(newAggregateID, procID)
        guard status == noErr else {
            stop()
            throw SystemAudioTapError.startFailed(status)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapFormat = nil
        tapUUID = nil
    }

    private func makeTapDescription(for target: Target) throws -> CATapDescription {
        let description: CATapDescription
        switch target {
        case .allProcesses:
            var excluded: [AudioObjectID] = []
            if let own = Self.translatePID(ProcessInfo.processInfo.processIdentifier) {
                excluded.append(own)
            }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .app(let app):
            // Conferencing apps often render audio from a helper process, so
            // tap every process object that shares the app's bundle ID.
            let objects = Self.processObjects(withBundleID: app.bundleID)
            guard !objects.isEmpty else { throw SystemAudioTapError.processNotFound(app.name) }
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        description.name = "ToskVoice Meeting Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    // MARK: - Core Audio property helpers

    private static func readProcessObjectList() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &list) == noErr else { return nil }
        return list
    }

    private static func readProcessBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func readProcessProperty<T>(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr,
              Int(dataSize) == MemoryLayout<T>.size else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    /// All process objects belonging to an app, including its helper
    /// processes: browsers and conferencing apps render audio from helpers
    /// whose bundle ID extends the app's (com.google.Chrome.helper).
    private static func processObjects(withBundleID bundleID: String) -> [AudioObjectID] {
        (readProcessObjectList() ?? []).filter { objectID in
            guard let processBundleID = readProcessBundleID(objectID) else { return false }
            return processBundleID == bundleID || processBundleID.hasPrefix(bundleID + ".")
        }
    }

    private static func translatePID(_ pid: Int32) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifierPointer,
                &dataSize,
                &objectID
            )
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private func readTapFormat(_ tapID: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &description) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &description)
    }
}

/// Bridges Core Audio's realtime IO callback to a Sendable buffer handler
/// without inheriting the actor isolation of the code that created the tap.
private final class TapIOBridge: @unchecked Sendable {
    private let format: AVAudioFormat
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void

    init(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.format = format
        self.onBuffer = onBuffer
    }

    nonisolated func makeIOBlock() -> AudioDeviceIOBlock {
        { [format, onBuffer] _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inputData,
                deallocator: nil
            ), buffer.frameLength > 0 else { return }
            onBuffer(buffer)
        }
    }
}

enum SystemAudioTapError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)
    case unknownFormat
    case processNotFound(String)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            "Creating the system audio tap failed (\(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
        case .aggregateCreationFailed(let status): "Creating the capture device failed (\(status))."
        case .ioProcFailed(let status): "Starting the capture callback failed (\(status))."
        case .startFailed(let status): "Starting system audio capture failed (\(status))."
        case .unknownFormat: "The system audio tap did not report an audio format."
        case .processNotFound(let name): "\(name) has no active audio process to tap."
        }
    }
}
