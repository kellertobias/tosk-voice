import AppKit
import ApplicationServices
import AVFoundation
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var finalizedText = ""
    @Published private(set) var volatileText = ""
    @Published private(set) var waveform = Array(repeating: Float(0.06), count: 56)
    @Published private(set) var statusDetail = "Control–Option–Space to dictate"
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var availableLanguages: [Locale] = []

    let preferences: PreferencesStore
    let history: HistoryStore
    let modelPacks: ModelPackController

    private let speechSession = AppleSpeechSession()
    private let whisperSession = WhisperSpeechSession()
    private let correctionService = FoundationCorrectionService()
    private let speakerLabeler = SpeakerLabeler()
    private let correctionSpeaker = AVSpeechSynthesizer()
    private var ledger = TranscriptLedger()
    private var capturedTarget: CapturedTextTarget?
    private var stopRequested = false
    private var timedUtterances: [TimedUtterance] = []
    private var pendingProcessingTask: Task<Void, Never>?
    private var pendingCorrection: String?

    var onOverlayRequested: ((OverlayPlacement) -> Void)?
    var onOverlayDismissed: (() -> Void)?
    var onMenuNeedsUpdate: (() -> Void)?
    var onMeterLevel: ((Float) -> Void)?
    var onEditorExpansionRequested: ((String) -> Void)?

    private enum ActiveEngine { case apple, whisper }
    private var activeEngine: ActiveEngine?

    init(preferences: PreferencesStore, history: HistoryStore, modelPacks: ModelPackController) {
        self.preferences = preferences
        self.history = history
        self.modelPacks = modelPacks
        statusDetail = "\(preferences.toggleShortcut.label) to dictate"
        refreshDevices()
        Task { [weak self] in
            let languages = await DictationLanguages.available()
            self?.availableLanguages = languages
        }
    }

    /// True when Quick Dictation runs on the bilingual WhisperKit pack, which
    /// detects the language itself (the language picker is hidden then).
    var usesBilingualQuickDictation: Bool {
        preferences.quickDictationModel == .whisperBilingual
    }

    /// The language dictation actually uses: the picker override when set,
    /// otherwise English.
    var effectiveLocale: Locale { preferences.effectiveLocale }
    var displayText: String {
        [finalizedText, volatileText].filter { !$0.isEmpty }.joined(separator: finalizedText.isEmpty ? "" : " ")
    }

    /// Copies the transcript collected so far to the clipboard without
    /// finishing the session, so it can keep listening.
    func copyTranscript() {
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusDetail = "Copied to clipboard"
    }

    func refreshDevices() {
        let all = AudioDeviceManager.devices()
        inputDevices = all.filter(\.hasInput)
        outputDevices = all.filter(\.hasOutput)
    }

    func toggle() {
        if state.isActive { Task { await stop() } } else { Task { await start() } }
    }

    func start() async {
        guard !state.isActive else { return }
        guard await requestPermissions() else {
            fail("Microphone access is required")
            return
        }
        state = .preparing
        finalizedText = ""
        volatileText = ""
        waveform = Array(repeating: Float(0.06), count: 56)
        ledger = TranscriptLedger()
        stopRequested = false
        timedUtterances = []
        pendingProcessingTask = nil
        pendingCorrection = nil
        capturedTarget = CapturedTextTarget.capture()
        _ = capturedTarget?.beginListeningPlaceholder()
        statusDetail = !AXIsProcessTrusted()
            ? "No Accessibility permission — result will only be copied"
            : "Quick Dictation"
        onOverlayRequested?(preferences.overlayPlacement)
        onMenuNeedsUpdate?()
        await correctionService.beginDictation(
            enableEditing: preferences.spokenCorrectionsEnabled,
            enablePolishing: preferences.condensedOutputEnabled
        )

        do {
            if preferences.diarizationEnabled {
                statusDetail = "Preparing speaker model…"
                _ = try await modelPacks.prepareSpeakerKit()
            }
            if usesBilingualQuickDictation {
                statusDetail = "Preparing bilingual model…"
                let kit = try await modelPacks.prepareWhisper()
                try whisperSession.start(
                    whisperKit: kit,
                    glossary: preferences.glossary,
                    inputUID: preferences.selectedInputUID,
                    onText: { [weak self] confirmed, volatile in
                        self?.finalizedText = confirmed
                        self?.volatileText = volatile
                    },
                    onLevel: { [weak self] level in self?.receive(level: level) }
                )
                activeEngine = .whisper
            } else {
                try await speechSession.start(
                    locale: effectiveLocale,
                    glossary: preferences.glossary,
                    inputUID: preferences.selectedInputUID,
                    onText: { [weak self] text, isFinal, timing in self?.receive(text: text, isFinal: isFinal, timing: timing) },
                    onLevel: { [weak self] level in self?.receive(level: level) }
                )
                activeEngine = .apple
            }
            state = .listening
            onMenuNeedsUpdate?()
        } catch {
            await capturedTarget?.removeListeningPlaceholder()
            capturedTarget = nil
            fail(error.localizedDescription)
            await speechSession.cancel()
            await whisperSession.cancel()
            await correctionService.endDictation()
        }
    }

    func stop() async {
        guard state.isActive, !stopRequested else { return }
        stopRequested = true
        state = .finalizing
        onMenuNeedsUpdate?()
        if activeEngine == .whisper {
            let result = await whisperSession.stop()
            finalizedText = ""
            volatileText = ""
            for utterance in result.utterances { await processFinalUtterance(utterance.text, timing: utterance) }
            await applySpeakerLabels(audio: result.audio)
        } else {
            let audio = await speechSession.stop()
            await pendingProcessingTask?.value
            pendingProcessingTask = nil
            await applySpeakerLabels(audio: audio)
        }
        activeEngine = nil
        volatileText = ""
        finalizedText = ledger.text
        await commit()
        await correctionService.endDictation()
    }

    func cancel() async {
        guard state.isActive else { return }
        await speechSession.cancel()
        await whisperSession.cancel()
        await correctionService.endDictation()
        activeEngine = nil
        ledger = TranscriptLedger()
        timedUtterances = []
        pendingProcessingTask?.cancel()
        pendingProcessingTask = nil
        pendingCorrection = nil
        correctionSpeaker.stopSpeaking(at: .immediate)
        await capturedTarget?.removeListeningPlaceholder()
        capturedTarget = nil
        finalizedText = ""
        volatileText = ""
        state = .idle
        statusDetail = "Cancelled"
        onOverlayDismissed?()
        onMenuNeedsUpdate?()
    }

    /// Detaches the running dictation from its captured target (the
    /// listening placeholder is removed, nothing is inserted) and hands the
    /// text collected so far to the Dictation Editor window.
    func expandToEditor() {
        guard state.isActive else { return }
        let transcript = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await cancel()
            statusDetail = "Continued in Edit with Voice"
            onEditorExpansionRequested?(transcript)
        }
    }

    func selectInput(_ uid: String?) {
        preferences.selectedInputUID = uid
        onMenuNeedsUpdate?()
    }

    /// Switches the dictation language. While an Apple-engine session is
    /// listening, the speech engine restarts in place: pending utterances are
    /// finalized into the ledger first, so no text is lost.
    func selectLanguage(_ identifier: String) {
        let changed = effectiveLocale.identifier != identifier
        preferences.dictationLocaleID = identifier
        onMenuNeedsUpdate?()
        guard changed, activeEngine == .apple, state == .listening || state == .correcting else { return }
        Task { await restartAppleEngineForLanguageChange() }
    }

    private func restartAppleEngineForLanguageChange() async {
        guard activeEngine == .apple, !stopRequested else { return }
        statusDetail = "Switching to \(DictationLanguages.label(for: effectiveLocale))…"
        _ = await speechSession.stop()
        await pendingProcessingTask?.value
        pendingProcessingTask = nil
        guard state.isActive, !stopRequested else { return }
        do {
            try await speechSession.start(
                locale: effectiveLocale,
                glossary: preferences.glossary,
                inputUID: preferences.selectedInputUID,
                onText: { [weak self] text, isFinal, timing in self?.receive(text: text, isFinal: isFinal, timing: timing) },
                onLevel: { [weak self] level in self?.receive(level: level) }
            )
            statusDetail = "Listening in \(DictationLanguages.label(for: effectiveLocale))"
        } catch {
            fail(error.localizedDescription)
            await speechSession.cancel()
        }
    }

    func selectOutput(_ uid: String?) {
        preferences.selectedOutputUID = uid
        onMenuNeedsUpdate?()
    }

    func toggleDiarization() {
        preferences.diarizationEnabled.toggle()
        if preferences.diarizationEnabled { Task { _ = try? await modelPacks.prepareSpeakerKit() } }
        onMenuNeedsUpdate?()
    }

    func toggleSpokenCorrections() {
        preferences.spokenCorrectionsEnabled.toggle()
        onMenuNeedsUpdate?()
    }

    func toggleCondensedOutput() {
        preferences.condensedOutputEnabled.toggle()
        onMenuNeedsUpdate?()
    }

    private func receive(level: Float) {
        waveform.removeFirst()
        waveform.append(max(0.04, level))
        onMeterLevel?(level)
    }

    private func receive(text: String, isFinal: Bool, timing: TimedUtterance?) {
        if correctionSpeaker.isSpeaking || text.lowercased().contains("i couldn't apply that") { return }
        if isFinal {
            volatileText = ""
            let previous = pendingProcessingTask
            pendingProcessingTask = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                await self?.processFinalUtterance(text, timing: timing)
            }
        } else {
            volatileText = text
        }
    }

    private func processFinalUtterance(_ text: String, timing: TimedUtterance? = nil) async {
        guard preferences.spokenCorrectionsEnabled else {
            ledger.append(text)
            if let timing { timedUtterances.append(timing) }
            finalizedText = ledger.text
            return
        }

        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if ["cancel correction", "never mind", "korrektur abbrechen", "vergiss es"].contains(normalized) {
            pendingCorrection = nil
            state = stopRequested ? .finalizing : .listening
            statusDetail = "Correction cancelled"
            return
        }
        if let pendingCorrection {
            state = .correcting
            let clarified = "\(pendingCorrection)\nCLARIFICATION: \(text)"
            if let revised = await correctionService.integrate(transcript: ledger.text, utterance: clarified) {
                ledger.replaceAll(with: revised)
                self.pendingCorrection = nil
                finalizedText = ledger.text
                state = stopRequested ? .finalizing : .listening
                statusDetail = "Correction applied"
            } else {
                askForCorrectionClarification()
            }
            return
        }
        if ledger.applyStandaloneCommand(text) {
            finalizedText = ledger.text
            statusDetail = "Correction applied"
            return
        }
        let likelyCorrection = CorrectionTrigger.shouldAskModelToEdit(text)
        if LiveDraftRouting.shouldUseModel(hasStagedText: !ledger.text.isEmpty, utterance: text) {
            state = .correcting
            statusDetail = likelyCorrection ? "Applying spoken correction…" : "Updating live draft…"
            if let revised = await correctionService.integrate(transcript: ledger.text, utterance: text) {
                ledger.replaceAll(with: revised)
                if let timing { timedUtterances.append(timing) }
                finalizedText = ledger.text
                state = stopRequested ? .finalizing : .listening
                statusDetail = likelyCorrection ? "Correction applied" : "Live draft updated"
                return
            }
            state = stopRequested ? .finalizing : .listening
            if likelyCorrection {
                pendingCorrection = text
                askForCorrectionClarification()
            } else {
                ledger.append(text)
                if let timing { timedUtterances.append(timing) }
                finalizedText = ledger.text
                statusDetail = "Added without model editing"
            }
            return
        }
        ledger.append(text)
        if let timing { timedUtterances.append(timing) }
        finalizedText = ledger.text
    }

    private func askForCorrectionClarification() {
        state = stopRequested ? .finalizing : .listening
        statusDetail = "Please clarify: for example, “replace A with B,” or say “cancel correction.”"
        guard !stopRequested, !correctionSpeaker.isSpeaking else { return }
        let utterance = AVSpeechUtterance(string: "I couldn't apply that. Please say replace A with B, or say cancel correction.")
        utterance.rate = 0.48
        correctionSpeaker.speak(utterance)
    }

    private func applySpeakerLabels(audio: [Float]) async {
        guard preferences.diarizationEnabled, let kit = modelPacks.speakerKit else { return }
        statusDetail = "Identifying speakers…"
        do {
            let labels = try await speakerLabeler.labels(audio: audio, utterances: timedUtterances, using: kit)
            ledger.assignSpeakers(labels)
            finalizedText = ledger.text
        } catch {
            statusDetail = "Speaker labeling unavailable: \(error.localizedDescription)"
        }
    }

    private func commit() async {
        var text = ledger.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            await capturedTarget?.removeListeningPlaceholder()
            capturedTarget = nil
            state = .idle
            statusDetail = "Nothing recorded"
            dismissSoon()
            return
        }

        if preferences.condensedOutputEnabled {
            state = .correcting
            statusDetail = "Polishing final text…"
            onMenuNeedsUpdate?()
            if let condensed = await correctionService.condense(text) {
                ledger.replaceAll(with: condensed)
                finalizedText = ledger.text
                text = condensed
            }
        }
        var destinationDescription = "Focused text field"
        var succeeded = false
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let capturedTarget {
            await capturedTarget.focusCapturedField()
            if capturedTarget.hasListeningPlaceholder {
                succeeded = await capturedTarget.replaceListeningPlaceholder(with: text)
            }
            if !succeeded {
                succeeded = await capturedTarget.insert(text)
            }
        }
        if !succeeded {
            destinationDescription = "Clipboard fallback"
        }
        capturedTarget = nil

        history.add(HistoryEntry(text: text, profileName: "Quick Dictation", destinationDescription: destinationDescription))
        let accessibilityMissing = !AXIsProcessTrusted()
        state = succeeded
            ? .committed
            : .failed(accessibilityMissing
                ? "Copied; ToskVoice needs Accessibility permission to insert text"
                : "Copied; original destination unavailable")
        statusDetail = succeeded
            ? destinationDescription
            : accessibilityMissing
                ? "Enable ToskVoice under System Settings → Privacy & Security → Accessibility, then restart it"
                : "Transcript preserved in History and Clipboard"
        onMenuNeedsUpdate?()
        dismissSoon()
    }

    private func dismissSoon() {
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            if !state.isActive {
                onOverlayDismissed?()
                state = .idle
                statusDetail = "\(preferences.toggleShortcut.label) to dictate"
                onMenuNeedsUpdate?()
            }
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        statusDetail = message
        onOverlayRequested?(preferences.overlayPlacement)
        onMenuNeedsUpdate?()
        dismissSoon()
    }

    private func requestPermissions() async -> Bool {
        let microphone: Bool
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            microphone = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
        return microphone
    }
}
