@preconcurrency import AVFoundation
import Foundation
import Speech

@MainActor
final class AppleSpeechSession {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var tapProcessor: AudioTapProcessor?
    private var capturedAudio: [Float] = []

    func start(
        locale requestedLocale: Locale,
        glossary: [String],
        inputUID: String?,
        onText: @escaping @MainActor (String, Bool, TimedUtterance?) -> Void,
        onLevel: @escaping @MainActor @Sendable (Float) -> Void
    ) async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        guard let locale else { throw SpeechSessionError.unsupportedLocale(requestedLocale.identifier) }

        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        let status = await AssetInventory.status(forModules: modules)
        if status == .unsupported { throw SpeechSessionError.unsupportedLocale(locale.identifier) }
        if status < .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }

        let context = AnalysisContext()
        context.contextualStrings[.general] = glossary
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.setContext(context)

        let audioEngine = AVAudioEngine()
        try AudioDeviceManager.configureInput(inputUID, for: audioEngine)
        let inputNode = audioEngine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else { throw SpeechSessionError.noMicrophone }
        let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: naturalFormat) ?? naturalFormat
        try await analyzer.prepareToAnalyze(in: analysisFormat)

        let converter: AVAudioConverter?
        if AudioSignalProcessor.formatsMatch(naturalFormat, analysisFormat) {
            converter = nil
        } else {
            guard let audioConverter = AVAudioConverter(from: naturalFormat, to: analysisFormat) else {
                throw SpeechSessionError.cannotStart
            }
            converter = audioConverter
        }

        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        let stream = AsyncStream<AnalyzerInput> { continuation = $0 }
        guard let continuation else { throw SpeechSessionError.cannotStart }
        inputContinuation = continuation
        self.analyzer = analyzer
        engine = audioEngine
        capturedAudio = []

        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let timing = TimedUtterance(
                        text: text,
                        start: Float(result.range.start.seconds),
                        end: Float(result.range.end.seconds)
                    )
                    onText(text, result.isFinal, timing)
                }
            } catch {
                // The coordinator reports analyzer/start failures; cancellation is expected on stop.
            }
        }

        analysisTask = Task {
            do { try await analyzer.start(inputSequence: stream) }
            catch { /* surfaced by finalization or a failed result stream */ }
        }

        let tapProcessor = AudioTapProcessor(
            continuation: continuation,
            converter: converter,
            analysisFormat: analysisFormat
        ) { @MainActor [weak self] samples, level in
                self?.capturedAudio.append(contentsOf: samples)
                onLevel(level)
        }
        self.tapProcessor = tapProcessor

        // The input-node tap must use the microphone's native hardware format.
        // Its handler is created by a non-actor bridge because Core Audio calls
        // it from a realtime queue, never from the main actor.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: naturalFormat,
            block: tapProcessor.makeHandler()
        )
        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() async -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        inputContinuation?.finish()
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch { }
        _ = await analysisTask?.result
        _ = await resultTask?.result
        let audio = capturedAudio
        capturedAudio = []
        tearDown()
        return audio
    }

    func cancel() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        analysisTask?.cancel()
        resultTask?.cancel()
        capturedAudio = []
        tearDown()
    }

    private func tearDown() {
        engine = nil
        analyzer = nil
        inputContinuation = nil
        analysisTask = nil
        resultTask = nil
        tapProcessor = nil
    }

}

final class AudioTapProcessor: @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter?
    private let analysisFormat: AVAudioFormat
    private let onSamples: @MainActor @Sendable ([Float], Float) -> Void

    init(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        converter: AVAudioConverter?,
        analysisFormat: AVAudioFormat,
        onSamples: @escaping @MainActor @Sendable ([Float], Float) -> Void
    ) {
        self.continuation = continuation
        self.converter = converter
        self.analysisFormat = analysisFormat
        self.onSamples = onSamples
    }

    nonisolated func makeHandler() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, _ in process(buffer) }
    }

    nonisolated private func process(_ buffer: AVAudioPCMBuffer) {
        guard let captured = AudioSignalProcessor.copy(buffer) else { return }
        let analyzerBuffer: AVAudioPCMBuffer
        if let converter {
            guard let converted = AudioSignalProcessor.convert(captured, to: analysisFormat, using: converter) else { return }
            analyzerBuffer = converted
        } else {
            analyzerBuffer = captured
        }

        continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
        let level = AudioSignalProcessor.level(of: captured)
        let samples = AudioSignalProcessor.mono16kSamples(from: captured)
        Task { @MainActor [onSamples] in
            onSamples(samples, level)
        }
    }
}

enum AudioSignalProcessor {
    nonisolated static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return 0 }

        var sum: Float = 0
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let sample = channels[channel][frame]
                sum += sample * sample
            }
        }
        let rms = sqrt(sum / Float(channelCount * frameCount))
        guard rms > 0 else { return 0 }

        // Map the useful speech range (-60 dB through -10 dB) onto the meter.
        // Linear RMS made normal speech look nearly flat on typical Mac inputs.
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 50))
    }

    nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copied = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copied.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let destination = copied.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
            return copied
        }
        return nil
    }

    nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let rateRatio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * rateRatio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, capacity)) else { return nil }

        let input = AudioConverterInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            input.next(inputStatus)
        }
        guard conversionError == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    nonisolated static func mono16kSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let source = buffer.floatChannelData?.pointee else { return [] }
        let frames = Int(buffer.frameLength)
        guard frames > 0, buffer.format.sampleRate > 0 else { return [] }
        let ratio = buffer.format.sampleRate / 16_000
        let outputCount = max(1, Int(Double(frames) / ratio))
        return (0..<outputCount).map { index in
            source[min(frames - 1, Int(Double(index) * ratio))]
        }
    }
}

private final class AudioConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

enum SpeechSessionError: LocalizedError {
    case unsupportedLocale(String)
    case noMicrophone
    case cannotStart

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let locale): "Speech recognition is unavailable for \(locale)."
        case .noMicrophone: "The selected microphone is unavailable."
        case .cannotStart: "Speech recognition could not start."
        }
    }
}
