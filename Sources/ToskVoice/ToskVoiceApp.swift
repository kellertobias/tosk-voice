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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = PreferencesStore()
        let history = HistoryStore()
        let modelPacks = ModelPackController()
        let agentPreferences = AgentPreferencesStore()
        model = AppModel(preferences: preferences, history: history, modelPacks: modelPacks)
        let historyWindow = HistoryWindowController(model: model)
        let textToSpeech = TextToSpeechWindowController(modelPacks: modelPacks, preferences: preferences)
        let voiceEditorWindow = VoiceEditorAgentWindowController(preferences: agentPreferences)
        voiceEditor = voiceEditorWindow
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
        menuController = MenuController(model: model, settings: settings, history: historyWindow, textToSpeech: textToSpeech, voiceEditor: voiceEditor)
        overlayController = OverlayController(model: model, statusButton: menuController.statusItem.button)

        model.onOverlayRequested = { [weak self] placement in self?.overlayController.show(at: placement) }
        model.onOverlayDismissed = { [weak self] in self?.overlayController.hide() }
        model.onMenuNeedsUpdate = { [weak self] in self?.menuController.updateStatus() }
        model.onMeterLevel = { [weak self] level in self?.menuController.updateMeter(level: level) }

        shortcutManager = ShortcutManager(preferences: preferences)
        shortcutManager.onToggle = { [weak model] in model?.toggle() }
        shortcutManager.onPushStart = { [weak model] in Task { await model?.start() } }
        shortcutManager.onPushStop = { [weak model] in Task { await model?.stop() } }
        shortcutManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutManager?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "toskvoice", url.host == "edit",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let instruction = components.queryItems?.first(where: { $0.name == "instruction" })?.value ?? ""
        voiceEditor.show(instruction: instruction)
    }
}
