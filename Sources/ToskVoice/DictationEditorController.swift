import AppKit
import AVFoundation
import Foundation

/// State and behavior of the Dictation Editor window: a free-form text
/// document that live dictation is spliced into at the caret (or over the
/// selection), with optional on-device correction intelligence and a
/// push-to-talk capture mode.
@MainActor
final class DictationEditorController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published var intelligenceEnabled = false {
        didSet {
            guard intelligenceEnabled != oldValue else { return }
            let service = correctionService
            let enabled = intelligenceEnabled
            Task {
                if enabled {
                    await service.beginDictation(enableEditing: true, enablePolishing: false)
                } else {
                    await service.endDictation()
                }
            }
        }
    }
    @Published var status = "Ready"
    @Published private(set) var waveform = Array(repeating: Float(0.06), count: 56)
    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedInputUID: String?
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published private(set) var hasContent = false
    @Published private(set) var isTalkKeyHeld = false
    @Published private(set) var isApplyingCorrection = false
    @Published private(set) var isImproving = false
    @Published var availableLanguages: [Locale] = []
    @Published private(set) var localeID: String

    /// Set by the text-area representable once the NSTextView exists.
    var bridge: DictationEditorTextBridge? {
        didSet {
            guard let bridge else { return }
            bridge.onEdit = { [weak self] in
                self?.isDirty = true
                self?.refreshContentState()
            }
            // Deferred: makeNSView runs during a SwiftUI update, where
            // publishing further changes is not allowed.
            Task { @MainActor [weak self] in self?.applyPendingDocument() }
        }
    }

    private let session = DictationEditorSession()
    private let whisperSession = WhisperSpeechSession()
    private let correctionService = FoundationCorrectionService()
    private let preferences: PreferencesStore
    private let modelPacks: ModelPackController
    private(set) var sessionStart: Date?
    private var pendingDocument: (text: String, url: URL?, dirty: Bool)?
    /// True while the running session uses the WhisperKit engine (chosen in
    /// Settings → Models). Whisper detects the language itself and has no
    /// pause/push-to-talk gates.
    private(set) var usesWhisper = false
    /// The part of Whisper's growing confirmed transcript already inserted
    /// into the document; new confirmed text is inserted as the delta.
    private var whisperInsertedPrefix = ""

    init(preferences: PreferencesStore, modelPacks: ModelPackController) {
        self.preferences = preferences
        self.modelPacks = modelPacks
        selectedInputUID = preferences.selectedInputUID
        localeID = preferences.dictationLocaleID ?? "en-US"
    }

    var hasUnsavedContent: Bool { isDirty && hasContent }

    /// Pause and push-to-talk gate the Apple engine's audio tap; WhisperKit
    /// has no gates, so the buttons are disabled when it is selected.
    var supportsGates: Bool { preferences.editWithVoiceModel == .appleSpeech }

    /// Starts a regular (continuous) session.
    func startContinuous() {
        guard !isRunning else { return }
        isPaused = false
        isTalkKeyHeld = false
        toggle()
    }

    func refreshDevices() {
        inputDevices = AudioDeviceManager.devices().filter(\.hasInput)
        if let selectedInputUID, !inputDevices.contains(where: { $0.uid == selectedInputUID }) {
            self.selectedInputUID = nil
        }
        Task { [weak self] in
            let languages = await DictationLanguages.available()
            self?.availableLanguages = languages
        }
    }

    /// Switches the dictation language; a running session restarts in place
    /// (pending utterances are finalized first, the document is untouched).
    func selectLanguage(_ identifier: String) {
        guard identifier != localeID else { return }
        localeID = identifier
        guard isRunning else { return }
        status = "Switching to \(DictationLanguages.label(forIdentifier: identifier))…"
        Task {
            await stop()
            await start(resetTranscript: false)
        }
    }

    // MARK: - Session control

    func toggle() {
        if isRunning {
            Task { await stop() }
            return
        }
        if !hasContent {
            Task { await start(resetTranscript: true) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Start a new dictation?"
        alert.informativeText = "The editor already contains text. You can continue dictating into it at the cursor or start over."
        alert.addButton(withTitle: "Continue in Text")
        alert.addButton(withTitle: "Start New")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await start(resetTranscript: false) }
        case .alertSecondButtonReturn:
            if hasUnsavedContent {
                let confirm = NSAlert()
                confirm.messageText = "Discard the unsaved text?"
                confirm.informativeText = "The current text has not been saved. Starting new discards it."
                confirm.addButton(withTitle: "Save First…")
                confirm.addButton(withTitle: "Discard")
                confirm.addButton(withTitle: "Cancel")
                switch confirm.runModal() {
                case .alertFirstButtonReturn:
                    guard save(in: NSApp.keyWindow) else { return }
                case .alertSecondButtonReturn:
                    break
                default:
                    return
                }
            }
            Task { await start(resetTranscript: true) }
        default:
            break
        }
    }

    func start(resetTranscript: Bool) async {
        guard !isRunning else { return }
        guard await requestMicrophoneAccess() else {
            status = "Microphone access is required"
            return
        }
        if resetTranscript {
            bridge?.replaceDocument(with: "")
            fileURL = nil
            isDirty = false
            sessionStart = nil
            refreshContentState()
        }
        status = "Starting…"
        do {
            if preferences.editWithVoiceModel == .whisperBilingual {
                status = "Preparing bilingual model…"
                let kit = try await modelPacks.prepareWhisper()
                whisperInsertedPrefix = ""
                usesWhisper = true
                try whisperSession.start(
                    whisperKit: kit,
                    glossary: preferences.glossary,
                    inputUID: selectedInputUID,
                    onText: { [weak self] confirmed, volatile in self?.receiveWhisper(confirmed: confirmed, volatile: volatile) },
                    onLevel: { [weak self] level in self?.receive(level: level) }
                )
            } else {
                usesWhisper = false
                // Close the gate before audio starts flowing so a session
                // started paused (push-to-talk) never leaks the first buffers.
                session.isPaused = false
                session.isTalkGated = !isCapturingState
                try await session.start(
                    locale: Locale(identifier: localeID),
                    glossary: preferences.glossary,
                    inputUID: selectedInputUID,
                    onText: { [weak self] text, isFinal, _ in self?.receive(text: text, isFinal: isFinal) },
                    onLevel: { [weak self] level in self?.receive(level: level) }
                )
            }
            if sessionStart == nil { sessionStart = Date() }
            isRunning = true
            applyGates()
        } catch {
            usesWhisper = false
            status = error.localizedDescription
        }
    }

    func stop() async {
        guard isRunning else { return }
        status = "Finishing…"
        if usesWhisper {
            let result = await whisperSession.stop()
            let confirmed = result.utterances.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            insertWhisperDelta(from: confirmed)
            usesWhisper = false
        } else {
            await session.stop()
        }
        isRunning = false
        isPaused = false
        isTalkKeyHeld = false
        bridge?.clearVolatile()
        bridge?.discardAnchor()
        resetWaveform()
        status = "Ready"
    }

    /// Pause toggles between paused and regular (continuous) transcription;
    /// resuming always leaves push-to-talk.
    func togglePause() {
        guard isRunning, !usesWhisper else { return }
        isPaused.toggle()
        if !isPaused { isTalkKeyHeld = false }
        applyGates()
    }

    /// Push-to-talk: called by the window's flags-changed monitor for the
    /// left Control key and by the on-screen PTT button. Audio flows only
    /// while held; releasing leaves the session paused (resume regular
    /// transcription with the Pause button). Holding while no session runs
    /// starts one that captures only during the hold.
    func talkKeyChanged(held: Bool) {
        guard !usesWhisper else { return }
        if !isRunning {
            guard held, supportsGates else { return }
            isPaused = true
            isTalkKeyHeld = true
            Task {
                await start(resetTranscript: false)
                // The key may have been released while the engine started.
                if !NSEvent.modifierFlags.contains(.control) { isTalkKeyHeld = false }
                applyGates()
            }
            return
        }
        guard isTalkKeyHeld != held else { return }
        isTalkKeyHeld = held
        // Releasing PTT parks the session in pause instead of falling back
        // to continuous capture.
        if !held { isPaused = true }
        applyGates()
    }

    /// Audio flows while PTT is held, or in regular mode when not paused.
    private var isCapturingState: Bool { isTalkKeyHeld || !isPaused }

    private func applyGates() {
        if usesWhisper {
            status = "Listening (WhisperKit, English + German)"
            return
        }
        session.isPaused = !isCapturingState
        session.isTalkGated = false
        if !(isRunning && isCapturingState) { resetWaveform() }
        guard isRunning else { return }
        if isTalkKeyHeld {
            status = "Listening (push-to-talk)"
        } else if isPaused {
            status = "Paused — press Pause to resume, or hold left ⌃"
        } else {
            status = "Listening"
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Transcription results

    private func receive(level: Float) {
        waveform.removeFirst()
        waveform.append(max(0.04, level))
    }

    private func receive(text: String, isFinal: Bool) {
        guard let bridge else { return }
        if isFinal {
            bridge.clearVolatile()
            routeFinal(text)
        } else {
            bridge.showVolatile(text)
        }
    }

    /// Whisper reports the whole confirmed transcript on every update; only
    /// the not-yet-inserted suffix goes into the document.
    private func receiveWhisper(confirmed: String, volatile: String) {
        guard bridge != nil else { return }
        insertWhisperDelta(from: confirmed)
        if volatile.isEmpty {
            bridge?.clearVolatile()
        } else {
            bridge?.showVolatile(volatile)
        }
    }

    private func insertWhisperDelta(from confirmed: String) {
        let trimmed = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != whisperInsertedPrefix else { return }
        var delta = trimmed
        if trimmed.hasPrefix(whisperInsertedPrefix) {
            delta = String(trimmed.dropFirst(whisperInsertedPrefix.count))
        }
        whisperInsertedPrefix = trimmed
        delta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !delta.isEmpty else { return }
        bridge?.clearVolatile()
        routeFinal(delta)
    }

    private func routeFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            bridge?.discardAnchor()
            return
        }
        if intelligenceEnabled, hasContent,
           CorrectionTrigger.shouldAskModelToEdit(trimmed) || SpokenReplacement.parse(trimmed) != nil {
            applyModelCorrection(trimmed)
            return
        }
        bridge?.insertFinal(trimmed)
    }

    /// Applies a spoken correction ("replace A with B", "strike that", …) to
    /// the whole document with the on-device model. The rewrite is undoable
    /// (⌘Z) and is skipped when the text changed while the model was working.
    private func applyModelCorrection(_ utterance: String) {
        guard let bridge else { return }
        bridge.discardAnchor()
        let original = bridge.documentText
        isApplyingCorrection = true
        status = "Applying spoken correction…"
        let service = correctionService
        Task { [weak self] in
            let revised = await service.integrate(transcript: original, utterance: utterance)
            guard let self else { return }
            self.isApplyingCorrection = false
            guard let bridge = self.bridge else { return }
            if bridge.documentText != original {
                self.status = "Text changed while correcting — correction skipped"
            } else if let revised {
                bridge.replaceDocumentRegisteringUndo(with: revised)
                self.status = "Correction applied (⌘Z to undo)"
            } else if let literal = SpokenReplacement.apply(to: original, utterance: utterance) {
                bridge.replaceDocumentRegisteringUndo(with: literal)
                self.status = "Correction applied (⌘Z to undo)"
            } else {
                self.status = "Couldn't apply that — try “replace A with B”"
            }
        }
    }

    /// "Improve Result": removes filler words, stutters, and other verbal
    /// artifacts from the whole document using the provider configured in
    /// Settings. The rewrite is a single undoable edit (⌘Z).
    func improveResult() {
        guard let bridge, !isImproving else { return }
        let original = bridge.documentText
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let configuration = preferences.improvement
        isImproving = true
        status = "Improving text…"
        Task { [weak self] in
            defer { self?.isImproving = false }
            do {
                let improved = try await TextImprovementService.improve(original, configuration: configuration)
                guard let self, let bridge = self.bridge else { return }
                if bridge.documentText != original {
                    self.status = "Text changed while improving — result discarded"
                } else {
                    bridge.replaceDocumentRegisteringUndo(with: improved)
                    self.status = "Result improved (⌘Z to undo)"
                }
            } catch {
                self?.status = error.localizedDescription
            }
        }
    }

    // MARK: - Document handling

    func seedExpandedTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let bridge {
            bridge.appendParagraph(trimmed)
        } else {
            pendingDocument = (trimmed, nil, true)
        }
    }

    @discardableResult
    func openFile(url: URL) -> Bool {
        let content: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            content = utf8
        } else if let latin = try? String(contentsOf: url, encoding: .isoLatin1) {
            content = latin
        } else {
            status = "Could not read \(url.lastPathComponent) as text"
            return false
        }
        if let bridge {
            bridge.replaceDocument(with: content)
            refreshContentState()
        } else {
            pendingDocument = (content, url, false)
            hasContent = !content.isEmpty
        }
        fileURL = url
        isDirty = false
        status = "Opened \(url.lastPathComponent)"
        return true
    }

    func copyDocument() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bridge?.documentText ?? "", forType: .string)
        status = "Copied to Clipboard"
    }

    /// Empties the document so reopening the window starts blank. Called when
    /// the window closes, after the session has been stopped.
    func resetDocument() {
        bridge?.replaceDocument(with: "")
        bridge?.clearVolatile()
        bridge?.discardAnchor()
        pendingDocument = nil
        fileURL = nil
        isDirty = false
        sessionStart = nil
        whisperInsertedPrefix = ""
        refreshContentState()
        status = "Ready"
    }

    /// Writes to the opened file, or falls back to Save As when the document
    /// has no file yet. Returns true when the file was written.
    @discardableResult
    func save(in window: NSWindow?) -> Bool {
        guard let fileURL else { return saveAs(in: window) }
        return write(to: fileURL)
    }

    @discardableResult
    func saveAs(in window: NSWindow?) -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if let fileURL {
            panel.nameFieldStringValue = fileURL.lastPathComponent
            panel.directoryURL = fileURL.deletingLastPathComponent()
        } else {
            panel.nameFieldStringValue = "Dictation \(Self.fileNameFormatter.string(from: sessionStart ?? Date())).md"
        }
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            try (bridge?.documentText ?? "").write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            isDirty = false
            status = "Saved to \(url.lastPathComponent)"
            return true
        } catch {
            status = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    private func refreshContentState() {
        hasContent = !(bridge?.documentText.isEmpty ?? true)
    }

    private func applyPendingDocument() {
        guard let bridge, let pending = pendingDocument else { return }
        pendingDocument = nil
        bridge.replaceDocument(with: pending.text)
        fileURL = pending.url
        isDirty = pending.dirty
        refreshContentState()
    }

    private func resetWaveform() {
        waveform = Array(repeating: Float(0.06), count: 56)
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()
}
