@preconcurrency import AVFoundation
import Foundation
import Speech

/// One transcription channel of a meeting: a SpeechAnalyzer fed by an
/// arbitrary audio source (microphone engine or system audio tap).
@MainActor
final class MeetingTranscriptionLane {
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var processor: AudioTapProcessor?

    /// Prepares the analyzer for `inputFormat` and returns a realtime-safe
    /// handler that the audio source calls with buffers in that format.
    func start(
        locale requestedLocale: Locale,
        glossary: [String],
        inputFormat: AVAudioFormat,
        onText: @escaping @MainActor (String, Bool, TimedUtterance?) -> Void,
        onLevel: @escaping @MainActor @Sendable (Float) -> Void
    ) async throws -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
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

        let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: inputFormat) ?? inputFormat
        try await analyzer.prepareToAnalyze(in: analysisFormat)

        let converter: AVAudioConverter?
        if AudioSignalProcessor.formatsMatch(inputFormat, analysisFormat) {
            converter = nil
        } else {
            guard let audioConverter = AVAudioConverter(from: inputFormat, to: analysisFormat) else {
                throw SpeechSessionError.cannotStart
            }
            converter = audioConverter
        }

        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        let stream = AsyncStream<AnalyzerInput> { continuation = $0 }
        guard let continuation else { throw SpeechSessionError.cannotStart }
        inputContinuation = continuation
        self.analyzer = analyzer

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
                // Cancellation is expected on stop; start failures surface in the controller.
            }
        }

        analysisTask = Task {
            do { try await analyzer.start(inputSequence: stream) }
            catch { /* surfaced through a failed result stream */ }
        }

        let processor = AudioTapProcessor(
            continuation: continuation,
            converter: converter,
            analysisFormat: analysisFormat
        ) { @MainActor _, level in
            onLevel(level)
        }
        self.processor = processor
        return processor.makeHandler()
    }

    func finish() async {
        inputContinuation?.finish()
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() } catch { }
        _ = await analysisTask?.result
        _ = await resultTask?.result
        tearDown()
    }

    func cancel() async {
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        analysisTask?.cancel()
        resultTask?.cancel()
        tearDown()
    }

    private func tearDown() {
        analyzer = nil
        inputContinuation = nil
        analysisTask = nil
        resultTask = nil
        processor = nil
    }
}

enum MeetingSpeaker: String, Sendable {
    case me = "Me"
    case remote = "Remote"
}

struct MeetingSegment: Identifiable, Sendable {
    let id = UUID()
    let speaker: MeetingSpeaker
    var text: String
    let capturedAt: Date
    let start: Float
    let end: Float
}

/// Thread-safe flag the realtime audio handlers consult to drop buffers
/// while the transcript is paused.
final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }
}

/// Runs a meeting-transcript session: the microphone lane captures the local
/// speaker while a system audio process tap captures the remote participants,
/// each feeding its own SpeechAnalyzer.
@MainActor
final class MeetingSession {
    private let micLane = MeetingTranscriptionLane()
    private let remoteLane = MeetingTranscriptionLane()
    private let systemTap = SystemAudioTap()
    private var engine: AVAudioEngine?
    private let pauseGate = PauseGate()

    var isRunning: Bool { engine != nil }

    var isPaused: Bool {
        get { pauseGate.isPaused }
        set { pauseGate.isPaused = newValue }
    }

    struct Callbacks {
        var onSegment: @MainActor (MeetingSegment) -> Void
        var onVolatile: @MainActor (MeetingSpeaker, String) -> Void
        var onLevel: @MainActor @Sendable (MeetingSpeaker, Float) -> Void
    }

    func start(
        target: SystemAudioTap.Target,
        locale: Locale,
        glossary: [String],
        inputUID: String?,
        callbacks: Callbacks
    ) async throws {
        guard !isRunning else { return }

        // Remote lane first: creating the tap triggers the one-time
        // "System Audio Recording" consent prompt and fails fast if denied.
        do {
            let tapFormat = try systemTap.prepare(target: target)
            let remoteHandler = try await remoteLane.start(
                locale: locale,
                glossary: glossary,
                inputFormat: tapFormat,
                onText: { text, isFinal, timing in
                    if isFinal {
                        callbacks.onVolatile(.remote, "")
                        callbacks.onSegment(MeetingSegment(
                            speaker: .remote, text: text, capturedAt: Date(),
                            start: timing?.start ?? 0, end: timing?.end ?? 0
                        ))
                    } else {
                        callbacks.onVolatile(.remote, text)
                    }
                },
                onLevel: { level in callbacks.onLevel(.remote, level) }
            )
            try systemTap.run(onBuffer: Self.makeTapBufferHandler(remoteHandler, gate: pauseGate))
        } catch {
            systemTap.stop()
            await remoteLane.cancel()
            throw error
        }

        do {
            let audioEngine = AVAudioEngine()
            try AudioDeviceManager.configureInput(inputUID, for: audioEngine)
            let inputNode = audioEngine.inputNode
            let micFormat = inputNode.outputFormat(forBus: 0)
            guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw SpeechSessionError.noMicrophone }
            let micHandler = try await micLane.start(
                locale: locale,
                glossary: glossary,
                inputFormat: micFormat,
                onText: { text, isFinal, timing in
                    if isFinal {
                        callbacks.onVolatile(.me, "")
                        callbacks.onSegment(MeetingSegment(
                            speaker: .me, text: text, capturedAt: Date(),
                            start: timing?.start ?? 0, end: timing?.end ?? 0
                        ))
                    } else {
                        callbacks.onVolatile(.me, text)
                    }
                },
                onLevel: { level in callbacks.onLevel(.me, level) }
            )
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat, block: Self.makeGatedHandler(micHandler, gate: pauseGate))
            audioEngine.prepare()
            try audioEngine.start()
            engine = audioEngine
        } catch {
            systemTap.stop()
            await remoteLane.cancel()
            await micLane.cancel()
            engine = nil
            throw error
        }
    }

    /// Built by a nonisolated factory so the returned closure carries no
    /// actor isolation; Core Audio invokes it on its own realtime thread.
    private nonisolated static func makeTapBufferHandler(
        _ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        gate: PauseGate
    ) -> @Sendable (AVAudioPCMBuffer) -> Void {
        { buffer in
            guard !gate.isPaused else { return }
            handler(buffer, AVAudioTime(hostTime: mach_absolute_time()))
        }
    }

    private nonisolated static func makeGatedHandler(
        _ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        gate: PauseGate
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, time in
            guard !gate.isPaused else { return }
            handler(buffer, time)
        }
    }

    func stop() async {
        systemTap.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        await remoteLane.finish()
        await micLane.finish()
    }
}
