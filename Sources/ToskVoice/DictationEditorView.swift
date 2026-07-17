import AppKit
import Combine
import SwiftUI

/// Window host for the Dictation Editor. Mirrors the Meeting Transcript
/// window's behavior: appears in the Dock/app switcher while open, asks to
/// save unsaved text on close, and stops the session when the window closes.
@MainActor
final class DictationEditorWindowController: NSObject, NSWindowDelegate {
    let controller: DictationEditorController
    private var window: NSWindow?
    private var flagsMonitor: Any?
    private var chromeObservation: AnyCancellable?

    private static let baseTitle = "ToskVoice — Edit with Voice"

    init(preferences: PreferencesStore, modelPacks: ModelPackController) {
        controller = DictationEditorController(preferences: preferences, modelPacks: modelPacks)
        super.init()
    }

    func show() {
        controller.refreshDevices()
        if let window {
            DockPresence.shared.track(window)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: DictationEditorView(controller: controller))
        let window = NSWindow(contentViewController: hosting)
        window.title = Self.baseTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 620))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        installTalkKeyMonitor()
        observeChrome()
        DockPresence.shared.track(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the editor seeded with the transcript handed over from the
    /// dictation overlay and continues listening immediately.
    func showExpanded(transcript: String) {
        show()
        controller.seedExpandedTranscript(transcript)
        Task { await controller.start(resetTranscript: false) }
    }

    /// "Edit with Voice…": pick any text file and edit it in this window.
    func openFileWithDialog() {
        show()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        show()
        if controller.hasUnsavedContent {
            let alert = NSAlert()
            alert.messageText = "Save the current text?"
            alert.informativeText = "The editor contains unsaved text. It will be replaced by “\(url.lastPathComponent)”."
            alert.addButton(withTitle: "Save…")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard controller.save(in: window) else { return }
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        controller.openFile(url: url)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard controller.hasUnsavedContent else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the dictation?"
        alert.informativeText = "The editor contains unsaved text. It will be discarded when the window closes."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return controller.save(in: sender)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Task { await controller.stop() }
    }

    /// Left Control (key code 59) is the push-to-talk key while this window
    /// is key. A local monitor sees the flags change before the text view.
    private func installTalkKeyMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { [weak self] in
                guard let self, let window = self.window, window.isKeyWindow, event.keyCode == 59 else { return }
                self.controller.talkKeyChanged(held: event.modifierFlags.contains(.control))
            }
            return event
        }
    }

    private func observeChrome() {
        chromeObservation = controller.$fileURL
            .combineLatest(controller.$isDirty)
            .sink { [weak self] url, dirty in
                guard let self, let window = self.window else { return }
                window.title = url.map { "ToskVoice — \($0.lastPathComponent)" } ?? Self.baseTitle
                window.representedURL = url
                window.isDocumentEdited = dirty
            }
    }
}

private struct DictationEditorView: View {
    @ObservedObject var controller: DictationEditorController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            header
            pickers
            DictationEditorTextArea(controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
            footer
        }
        .padding(16)
        .frame(minWidth: 780, minHeight: 440)
    }

    private var isCapturing: Bool {
        controller.isRunning && (controller.isTalkKeyHeld || !controller.isPaused)
    }

    /// Top row: the waveform stretches across the window, the transport
    /// buttons sit on the right with the push-to-talk hint underneath.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            WaveformView(levels: controller.waveform, active: isCapturing, reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
            HStack(spacing: 8) {
                talkButton
                pauseButton
                Button(controller.isRunning ? "Stop" : "Start") {
                    if controller.isRunning { controller.toggle() } else { controller.startContinuous() }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isRunning ? .red : .accentColor)
            }
        }
    }

    /// Hold-to-talk: audio is transcribed only while this button (or the
    /// left Control key) is held; releasing parks the session in pause.
    private var talkButton: some View {
        Button("PTT") {}
            .buttonStyle(.bordered)
            .tint(controller.isTalkKeyHeld ? .accentColor : nil)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !controller.isTalkKeyHeld { controller.talkKeyChanged(held: true) }
                    }
                    .onEnded { _ in controller.talkKeyChanged(held: false) }
            )
            .disabled(!controller.supportsGates)
            .help("Push to talk: transcribes only while this button or the left ⌃ key is held. Release to pause.")
    }

    /// Dedicated Pause button: blinks while the session sits in pause;
    /// pressing it then resumes regular (continuous) transcription.
    private var pauseButton: some View {
        let blinking = controller.isRunning && controller.isPaused && !controller.isTalkKeyHeld
        return Button("Pause") { controller.togglePause() }
            .opacity(blinking ? 0.35 : 1)
            .animation(
                blinking && !reduceMotion
                    ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                    : .default,
                value: blinking
            )
            .disabled(!controller.isRunning || !controller.supportsGates)
            .help(controller.isPaused ? "Resume regular transcription" : "Pause listening")
    }

    /// Compact menu pickers, matching the Quick Dictation overlay's style.
    private var pickers: some View {
        HStack(spacing: 14) {
            Picker(selection: $controller.selectedInputUID) {
                Text("System Default").tag(String?.none)
                ForEach(controller.inputDevices, id: \.uid) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            } label: {
                Label("Microphone", systemImage: "mic")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .disabled(controller.isRunning)

            Picker(selection: Binding(
                get: { controller.localeID },
                set: { controller.selectLanguage($0) }
            )) {
                if !controller.availableLanguages.contains(where: { $0.identifier == controller.localeID }) {
                    Text(DictationLanguages.label(forIdentifier: controller.localeID)).tag(controller.localeID)
                }
                ForEach(controller.availableLanguages, id: \.identifier) { locale in
                    Text(DictationLanguages.label(for: locale)).tag(locale.identifier)
                }
            } label: {
                Label("Language", systemImage: "character.bubble")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("Dictation language — switching restarts listening in the new language, the text is kept.")

            Spacer()

            Text("Hold left ⌃ for PTT")
                .font(.caption2)
                .foregroundStyle(controller.isTalkKeyHeld ? Color.accentColor : Color.secondary)
            CopyableStatusText(text: controller.status)
                .font(.caption)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Copy Transcript") { controller.copyDocument() }
                .disabled(!controller.hasContent)
            Button {
                controller.improveResult()
            } label: {
                Label("Improve Result", systemImage: "sparkles")
            }
            .disabled(!controller.hasContent || controller.isImproving)
            .help("Remove “ehms”, stutters, and other verbal artifacts using the provider configured in Settings → General. Undo with ⌘Z.")
            if controller.isImproving {
                ProgressView().controlSize(.small)
            }
            if controller.fileURL == nil {
                Button("Save Transcript…") { controller.saveAs(in: NSApp.keyWindow) }
                    .disabled(!controller.hasContent)
            } else {
                Button("Save File") { controller.save(in: NSApp.keyWindow) }
                    .disabled(!controller.isDirty)
                Button("Save As…") { controller.saveAs(in: NSApp.keyWindow) }
            }
            Spacer()
            if controller.isApplyingCorrection {
                ProgressView().controlSize(.small)
            }
            Toggle("AI based spoken corrections", isOn: $controller.intelligenceEnabled)
                .help("Apply spoken corrections such as “replace A with B” or “strike that” to the text with Apple's on-device model. Can be toggled while dictating.")
        }
    }
}

/// The editable transcript. Dictated text is spliced in at a pending anchor:
/// the selection at the moment an utterance starts. Provisional (volatile)
/// text is shown in secondary color, marked with a custom attribute so its
/// range survives concurrent keyboard edits, and replaced by the final text.
@MainActor
final class DictationEditorTextBridge: NSObject, NSTextViewDelegate {
    private static let volatileMarker = NSAttributedString.Key("ToskVoice.volatileDictation")

    weak var textView: NSTextView?
    var onEdit: (() -> Void)?

    private var pendingAnchor: NSRange?

    static let bodyFont = NSFont.systemFont(ofSize: 15)

    static var finalAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor]
    }

    private static var volatileAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor, volatileMarker: true]
    }

    /// The document text without any provisional dictation still in flight.
    var documentText: String {
        guard let storage = textView?.textStorage else { return "" }
        guard let volatile = volatileRange() else { return storage.string }
        return (storage.string as NSString).replacingCharacters(in: volatile, with: "")
    }

    // MARK: - Dictation splicing

    func showVolatile(_ text: String) {
        guard let textView, let storage = textView.textStorage, !text.isEmpty else { return }
        let pinned = isPinnedToBottom
        let target: NSRange
        let caretFollows: Bool
        if let existing = volatileRange() {
            target = existing
            caretFollows = textView.selectedRange().location == existing.location + existing.length
        } else {
            // A new utterance anchors at the current selection; a non-empty
            // selection is spoken over and replaced.
            target = textView.selectedRange()
            pendingAnchor = NSRange(location: target.location, length: 0)
            caretFollows = true
        }
        let padded = EditorInsertion.padded(text, in: storage.string, replacing: target)
        storage.replaceCharacters(in: target, with: NSAttributedString(string: padded, attributes: Self.volatileAttributes))
        if caretFollows {
            textView.setSelectedRange(NSRange(location: target.location + (padded as NSString).length, length: 0))
        }
        if pinned { scrollToBottom() }
    }

    func clearVolatile() {
        guard let storage = textView?.textStorage, let range = volatileRange() else { return }
        storage.replaceCharacters(in: range, with: "")
        pendingAnchor = NSRange(location: range.location, length: 0)
    }

    func discardAnchor() {
        pendingAnchor = nil
    }

    /// Inserts the finalized utterance at the pending anchor (or the current
    /// selection) as a regular, undoable edit.
    func insertFinal(_ text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let pinned = isPinnedToBottom
        var target = pendingAnchor ?? textView.selectedRange()
        pendingAnchor = nil
        target.location = min(target.location, storage.length)
        target.length = min(target.length, storage.length - target.location)
        let selectionBefore = textView.selectedRange().location
        let caretFollows = selectionBefore >= target.location && selectionBefore <= target.location + target.length
        let padded = EditorInsertion.padded(text, in: storage.string, replacing: target)
        if textView.shouldChangeText(in: target, replacementString: padded) {
            textView.breakUndoCoalescing()
            storage.replaceCharacters(in: target, with: NSAttributedString(string: padded, attributes: Self.finalAttributes))
            textView.didChangeText()
        }
        if caretFollows {
            textView.setSelectedRange(NSRange(location: target.location + (padded as NSString).length, length: 0))
        }
        if pinned { scrollToBottom() }
    }

    // MARK: - Document operations

    /// Replaces the whole document without undo (opening a file, resetting).
    func replaceDocument(with text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        pendingAnchor = nil
        storage.setAttributedString(NSAttributedString(string: text, attributes: Self.finalAttributes))
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        scrollToBottom()
    }

    /// Replaces the whole document as an undoable edit (model corrections).
    func replaceDocumentRegisteringUndo(with text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        pendingAnchor = nil
        let full = NSRange(location: 0, length: storage.length)
        if textView.shouldChangeText(in: full, replacementString: text) {
            textView.breakUndoCoalescing()
            storage.replaceCharacters(in: full, with: NSAttributedString(string: text, attributes: Self.finalAttributes))
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        scrollToBottom()
    }

    /// Appends `text` as a new paragraph (transcript handed over from the
    /// overlay) as an undoable edit, and moves the caret to the end.
    func appendParagraph(_ text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        pendingAnchor = nil
        let separator = storage.length == 0 ? "" : "\n\n"
        let end = NSRange(location: storage.length, length: 0)
        let insertion = separator + text
        if textView.shouldChangeText(in: end, replacementString: insertion) {
            storage.replaceCharacters(in: end, with: NSAttributedString(string: insertion, attributes: Self.finalAttributes))
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        scrollToBottom()
    }

    // MARK: - Scrolling

    /// True while the view is scrolled to (near) the bottom; only then does
    /// new content auto-scroll. Scrolled-up positions are left alone until
    /// the user returns to the very bottom.
    private var isPinnedToBottom: Bool {
        guard let textView, let scrollView = textView.enclosingScrollView else { return true }
        let visible = scrollView.contentView.bounds
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        return visible.maxY >= documentHeight - 24
    }

    private func scrollToBottom() {
        guard let textView else { return }
        textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        onEdit?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Keep keyboard input in the regular style even next to gray
        // provisional text.
        textView?.typingAttributes = Self.finalAttributes
    }

    private func volatileRange() -> NSRange? {
        guard let storage = textView?.textStorage, storage.length > 0 else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(Self.volatileMarker, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            found = found.map { NSUnionRange($0, range) } ?? range
        }
        return found
    }
}

private struct DictationEditorTextArea: NSViewRepresentable {
    let controller: DictationEditorController

    func makeCoordinator() -> DictationEditorTextBridge {
        DictationEditorTextBridge()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.font = DictationEditorTextBridge.bodyFont
        textView.textColor = .labelColor
        textView.typingAttributes = DictationEditorTextBridge.finalAttributes
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        scrollView.hasVerticalScroller = true
        context.coordinator.textView = textView
        controller.bridge = context.coordinator
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
