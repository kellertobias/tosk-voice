import AppKit

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let settings: SettingsWindowController
    private let history: HistoryWindowController
    private let textToSpeech: TextToSpeechWindowController
    private let voiceEditor: VoiceEditorAgentWindowController
    private var meterLevels: [CGFloat] = [0.12, 0.12, 0.12, 0.12]
    private let statusMenu = NSMenu()

    init(model: AppModel, settings: SettingsWindowController, history: HistoryWindowController, textToSpeech: TextToSpeechWindowController, voiceEditor: VoiceEditorAgentWindowController) {
        self.model = model
        self.settings = settings
        self.history = history
        self.textToSpeech = textToSpeech
        self.voiceEditor = voiceEditor
        super.init()
        if let button = statusItem.button {
            setStatusImage(
                NSImage(systemSymbolName: "waveform", accessibilityDescription: "ToskVoice"),
                on: button
            )
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusMenu.delegate = self
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refreshDevices()
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    func updateStatus() {
        guard let button = statusItem.button else { return }
        let image = model.state.isActive
            ? Self.meterImage(levels: meterLevels, accessibilityDescription: model.state.label)
            : NSImage(systemSymbolName: "waveform", accessibilityDescription: model.state.label)
        setStatusImage(image, on: button)
    }

    func updateMeter(level: Float) {
        let normalized = CGFloat(min(max(level * 3.2, 0.08), 1))
        meterLevels.removeFirst()
        meterLevels.append(normalized)
        guard model.state.isActive, let button = statusItem.button else { return }
        setStatusImage(
            Self.meterImage(levels: meterLevels, accessibilityDescription: "ToskVoice listening"),
            on: button
        )
    }

    static func meterImage(levels: [CGFloat], accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let maximumHeights: [CGFloat] = [10, 16, 13, 8]
            for (index, rawLevel) in levels.prefix(4).enumerated() {
                let height = max(2.5, maximumHeights[index] * rawLevel)
                let rect = NSRect(x: CGFloat(index) * 4.25 + 0.75, y: (18 - height) / 2, width: 2.8, height: height)
                NSBezierPath(roundedRect: rect, xRadius: 1.4, yRadius: 1.4).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private func setStatusImage(_ image: NSImage?, on button: NSStatusBarButton) {
        image?.isTemplate = true
        button.contentTintColor = nil
        button.image = image
    }

    private func rebuild() {
        let menu = statusMenu
        menu.removeAllItems()
        let start = NSMenuItem(title: model.state.isActive ? "Stop Dictation" : "Start Dictation", action: #selector(toggle), keyEquivalent: "")
        start.target = self
        start.image = NSImage(systemSymbolName: model.state.isActive ? "stop.fill" : "mic.fill", accessibilityDescription: nil)
        menu.addItem(start)
        let shortcut = NSMenuItem(title: model.state.isActive ? "" : model.preferences.toggleShortcut.label, action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        if !model.state.isActive { menu.addItem(shortcut) }
        menu.addItem(.separator())

        menu.addItem(submenuItem(title: "Profile: \(model.profile.name)", image: "square.stack.3d.up", entries: model.preferences.profiles.map { profile in
            menuItem(profile.name, checked: profile.id == model.preferences.selectedProfileID) { [weak model] in model?.selectProfile(profile.id) }
        }))
        menu.addItem(submenuItem(title: "Microphone", image: "mic", entries: [
            menuItem("System Default", checked: model.preferences.selectedInputUID == nil) { [weak model] in model?.selectInput(nil) }
        ] + model.inputDevices.map { device in
            menuItem(device.name, checked: model.preferences.selectedInputUID == device.uid) { [weak model] in model?.selectInput(device.uid) }
        }))
        menu.addItem(submenuItem(title: "Output", image: "speaker.wave.2", entries: [
            menuItem("System Default", checked: model.preferences.selectedOutputUID == nil) { [weak model] in model?.selectOutput(nil) }
        ] + model.outputDevices.map { device in
            menuItem(device.name, checked: model.preferences.selectedOutputUID == device.uid) { [weak model] in model?.selectOutput(device.uid) }
        }))

        let speakers = NSMenuItem(title: "Multi-speaker Labels", action: #selector(toggleDiarization), keyEquivalent: "")
        speakers.target = self
        speakers.state = model.profile.diarizationEnabled ? .on : .off
        speakers.toolTip = "The optional SpeakerKit model downloads when first enabled."
        menu.addItem(speakers)

        let corrections = NSMenuItem(title: "Spoken Corrections", action: #selector(toggleSpokenCorrections), keyEquivalent: "")
        corrections.target = self
        corrections.state = model.profile.usesSpokenCorrections ? .on : .off
        corrections.toolTip = "Apply spoken corrections to the staged transcript immediately with Apple’s on-device model."
        menu.addItem(corrections)

        let condensedOutput = NSMenuItem(title: "Polish Final Text", action: #selector(toggleCondensedOutput), keyEquivalent: "")
        condensedOutput.target = self
        condensedOutput.state = model.profile.producesCondensedOutput ? .on : .off
        condensedOutput.toolTip = "Use Apple’s on-device language model to merge corrections and condense the final transcript."
        menu.addItem(condensedOutput)
        menu.addItem(.separator())

        let ttsItem = NSMenuItem(title: "Text to Speech…", action: #selector(showTextToSpeech), keyEquivalent: "")
        ttsItem.target = self
        ttsItem.image = NSImage(systemSymbolName: "speaker.wave.2.bubble", accessibilityDescription: nil)
        menu.addItem(ttsItem)

        let editorItem = NSMenuItem(title: "Voice Editor…", action: #selector(showVoiceEditor), keyEquivalent: "")
        editorItem.target = self
        editorItem.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        menu.addItem(editorItem)

        let historyItem = NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        menu.addItem(historyItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ToskVoice", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func submenuItem(title: String, image: String, entries: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
        let submenu = NSMenu(title: title)
        entries.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private func menuItem(_ title: String, checked: Bool, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        item.state = checked ? .on : .off
        return item
    }

    @objc private func toggle() { model.toggle() }
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
        } else {
            model.toggle()
        }
    }
    @objc private func showSettings() { settings.show() }
    @objc private func showHistory() { history.show() }
    @objc private func showTextToSpeech() { textToSpeech.show() }
    @objc private func showVoiceEditor() { voiceEditor.show() }
    @objc private func toggleDiarization() { model.toggleDiarization() }
    @objc private func toggleSpokenCorrections() { model.toggleSpokenCorrections() }
    @objc private func toggleCondensedOutput() { model.toggleCondensedOutput() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let closure: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        closure = action
        super.init(title: title, action: #selector(runClosure), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @MainActor @objc private func runClosure() { closure() }
}
