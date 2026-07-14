import AVFoundation
import CoreML
import Foundation
@preconcurrency import WhisperKit

@MainActor
final class WhisperSpeechSession {
    private var transcriber: AudioStreamTranscriber?
    private var transcriptionTask: Task<Void, Never>?
    private var latestSegments: [String] = []
    private var latestTimedSegments: [TimedUtterance] = []
    private var audioProcessor: (any AudioProcessing)?

    struct Result: Sendable {
        var utterances: [TimedUtterance]
        var audio: [Float]
    }

    func start(
        whisperKit: WhisperKit,
        glossary: [String],
        inputUID: String?,
        onText: @escaping @MainActor @Sendable (_ confirmed: String, _ volatile: String) -> Void,
        onLevel: @escaping @MainActor @Sendable (Float) -> Void
    ) throws {
        guard let tokenizer = whisperKit.tokenizer else { throw SpeechSessionError.cannotStart }
        let selectedDeviceID = inputUID.flatMap { uid in AudioDeviceManager.devices().first(where: { $0.uid == uid && $0.hasInput })?.id }
        let processor = SelectedInputAudioProcessor(deviceID: selectedDeviceID)
        whisperKit.audioProcessor = processor
        audioProcessor = processor
        let prompt = glossary.isEmpty ? nil : tokenizer.encode(text: "Vocabulary: " + glossary.joined(separator: ", "))
        let options = DecodingOptions(
            language: nil,
            usePrefillPrompt: false,
            detectLanguage: true,
            wordTimestamps: true,
            promptTokens: prompt
        )

        let stream = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options,
            requiredSegmentsForConfirmation: 1,
            silenceThreshold: 0.25,
            useVAD: true
        ) { [weak self] _, state in
            let confirmedSegments = state.confirmedSegments.map(\.text)
            let pendingSegments = state.unconfirmedSegments.map(\.text)
            let current = state.currentText == "Waiting for speech..." ? "" : state.currentText
            let confirmed = confirmedSegments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let pending = (pendingSegments + [current]).filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let allSegments = confirmedSegments + pendingSegments + (current.isEmpty ? [] : [current])
            let energy = state.bufferEnergy.suffix(8).max() ?? 0
            Task { @MainActor in
                self?.latestSegments = allSegments
                self?.latestTimedSegments = (state.confirmedSegments + state.unconfirmedSegments).map {
                    TimedUtterance(text: $0.text, start: $0.start, end: $0.end)
                }
                onText(confirmed, pending)
                onLevel(min(1, energy * 3))
            }
        }
        transcriber = stream
        transcriptionTask = Task {
            do { try await stream.startStreamTranscription() } catch { }
        }
    }

    func stop() async -> Result {
        let audio = audioProcessor.map { Array($0.audioSamples) } ?? []
        await transcriber?.stopStreamTranscription()
        _ = await transcriptionTask?.result
        audioProcessor?.purgeAudioSamples(keepingLast: 0)
        let timed = latestTimedSegments.isEmpty
            ? latestSegments.enumerated().map { TimedUtterance(text: $0.element, start: Float($0.offset), end: Float($0.offset + 1)) }
            : latestTimedSegments
        transcriber = nil
        transcriptionTask = nil
        latestSegments = []
        latestTimedSegments = []
        audioProcessor = nil
        return Result(utterances: timed, audio: audio)
    }

    func cancel() async {
        await transcriber?.stopStreamTranscription()
        transcriptionTask?.cancel()
        audioProcessor?.purgeAudioSamples(keepingLast: 0)
        transcriber = nil
        transcriptionTask = nil
        latestSegments = []
        latestTimedSegments = []
        audioProcessor = nil
    }
}

private final class SelectedInputAudioProcessor: AudioProcessing, @unchecked Sendable {
    private let base = AudioProcessor()
    private let deviceID: DeviceID?

    init(deviceID: UInt32?) { self.deviceID = deviceID }

    static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Swift.Result<[Float], Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
    }

    var audioSamples: ContiguousArray<Float> { base.audioSamples }
    var relativeEnergy: [Float] { base.relativeEnergy }
    var relativeEnergyWindow: Int {
        get { base.relativeEnergyWindow }
        set { base.relativeEnergyWindow = newValue }
    }

    func purgeAudioSamples(keepingLast keep: Int) { base.purgeAudioSamples(keepingLast: keep) }
    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try base.startRecordingLive(inputDeviceID: inputDeviceID ?? deviceID, callback: callback)
    }
    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        base.startStreamingRecordingLive(inputDeviceID: inputDeviceID ?? deviceID)
    }
    func pauseRecording() { base.pauseRecording() }
    func stopRecording() { base.stopRecording() }
    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try base.resumeRecordingLive(inputDeviceID: inputDeviceID ?? deviceID, callback: callback)
    }
    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        base.padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
    }
}
