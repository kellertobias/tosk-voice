import AppKit

@main
@MainActor
enum ToskVoiceMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var menuController: MenuController!
    private var overlayController: OverlayController!
    private var shortcutManager: ShortcutManager!
    private var voiceEditor: VoiceEditorAgentWindowController!
    private var serviceProvider: TextServiceProvider!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let preferences = PreferencesStore()
        let history = HistoryStore()
        let modelPacks = ModelPackController()
        let agentPreferences = AgentPreferencesStore()
        model = AppModel(preferences: preferences, history: history, modelPacks: modelPacks)
        let historyWindow = HistoryWindowController(model: model)
        let textToSpeech = TextToSpeechWindowController(modelPacks: modelPacks, preferences: preferences)
        let voiceEditorWindow = VoiceEditorAgentWindowController(preferences: agentPreferences)
        voiceEditor = voiceEditorWindow
        let appModel = model!
        let meeting = MeetingWindowController(preferences: preferences, modelPacks: modelPacks) { appModel.profile }
        let settings = SettingsWindowController(
            model: model,
            showTextToSpeech: { textToSpeech.show() },
            showVoiceEditor: { voiceEditorWindow.show() },
            installObsidianCompanion: { voiceEditorWindow.installObsidianCompanion() },
            copyZedConfiguration: { voiceEditorWindow.copyZedConfiguration() }
        )
        if let selectedTab = SettingsRelaunchState.consumeSelectedTab() {
            settings.show(tab: selectedTab)
        }
        menuController = MenuController(model: model, settings: settings, history: historyWindow, textToSpeech: textToSpeech, voiceEditor: voiceEditor, meeting: meeting)
        overlayController = OverlayController(model: model, statusButton: menuController.statusItem.button)

        model.onOverlayRequested = { [weak self] placement in self?.overlayController.show(at: placement) }
        model.onOverlayDismissed = { [weak self] in self?.overlayController.hide() }
        model.onMenuNeedsUpdate = { [weak self] in self?.menuController.updateStatus() }
        model.onMeterLevel = { [weak self] level in self?.menuController.updateMeter(level: level) }

        serviceProvider = TextServiceProvider(textToSpeech: textToSpeech)
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        textToSpeech.autoStartManagedServerIfEnabled()

        shortcutManager = ShortcutManager(preferences: preferences)
        shortcutManager.onToggle = { [weak model] in model?.toggle() }
        shortcutManager.onPushStart = { [weak model] in Task { await model?.start() } }
        shortcutManager.onPushStop = { [weak model] in Task { await model?.stop() } }
        shortcutManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutManager?.stop()
    }

    /// Accessory apps have no main menu, so ⌘V/⌘C/⌘X/⌘A, ⌘W, and ⌘Q key
    /// equivalents never fire in our windows. Install a hidden main menu:
    /// a standard Edit menu enables the clipboard shortcuts, and both ⌘W
    /// and ⌘Q close the key window — quitting stays in the status menu.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let closeViaQ = NSMenuItem(title: "Close Window", action: #selector(closeKeyWindow), keyEquivalent: "q")
        closeViaQ.target = self
        appMenu.addItem(closeViaQ)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// ⌘Q closes the key window instead of quitting the menu-bar app;
    /// Quit ToskVoice lives in the status-item menu.
    @objc private func closeKeyWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "toskvoice", url.host == "edit",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let instruction = components.queryItems?.first(where: { $0.name == "instruction" })?.value ?? ""
        voiceEditor.show(instruction: instruction)
    }
}

/// Handles the "ToskVoice: Speak Selection" entry in the system Services
/// menu (declared under NSServices in Info.plist). AppKit invokes the
/// message named there with the selected text on the pasteboard.
@MainActor
final class TextServiceProvider: NSObject {
    private let textToSpeech: TextToSpeechWindowController

    init(textToSpeech: TextToSpeechWindowController) {
        self.textToSpeech = textToSpeech
    }

    @objc func speakSelection(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        textToSpeech.show(text: text)
    }
}
