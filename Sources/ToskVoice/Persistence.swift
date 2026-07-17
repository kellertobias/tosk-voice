import Foundation

@MainActor
final class PreferencesStore: ObservableObject {
    @Published var selectedInputUID: String? { didSet { save() } }
    @Published var selectedOutputUID: String? { didSet { save() } }
    @Published var launchAtLogin: Bool { didSet { save() } }
    @Published var toggleShortcut: ToggleShortcutChoice { didSet { save() } }
    @Published var pushShortcut: PushShortcutChoice { didSet { save() } }
    @Published var ttsServer: TTSServerConfiguration { didSet { save() } }
    /// Language override for dictation (BCP-47 id); nil = English.
    @Published var dictationLocaleID: String? { didSet { save() } }
    @Published var historyRetention: HistoryRetention { didSet { save() } }
    @Published var improvement: TextImprovementConfiguration { didSet { save() } }
    /// Global vocabulary (names and domain terms) applied to every dictation.
    @Published var glossary: [String] { didSet { save() } }
    @Published var overlayPlacement: OverlayPlacement { didSet { save() } }
    @Published var diarizationEnabled: Bool { didSet { save() } }
    @Published var spokenCorrectionsEnabled: Bool { didSet { save() } }
    @Published var condensedOutputEnabled: Bool { didSet { save() } }
    /// Speech-to-text model per feature; only installed models are offered.
    @Published var quickDictationModel: TranscriptionModelChoice { didSet { save() } }
    @Published var editWithVoiceModel: TranscriptionModelChoice { didSet { save() } }
    @Published var meetingTranscriptModel: TranscriptionModelChoice { didSet { save() } }
    /// The text-to-speech engine chosen in Settings → Text to Speech.
    @Published var ttsProvider: TTSProviderChoice { didSet { save() } }

    /// The dictation language currently in effect.
    var effectiveLocale: Locale {
        Locale(identifier: dictationLocaleID ?? "en-US")
    }

    /// Shape of profiles saved by builds that still had multiple dictation
    /// profiles; the selected one seeds the flat settings on first launch.
    private struct LegacyProfile: Codable {
        var id: UUID
        var overlayPlacement: OverlayPlacement?
        var glossary: [String]?
        var diarizationEnabled: Bool?
        var spokenCorrectionsEnabled: Bool?
        var condensedOutputEnabled: Bool?
        var speechMode: String?
    }

    private struct Snapshot: Codable {
        var profiles: [LegacyProfile]?
        var selectedProfileID: UUID?
        var selectedInputUID: String?
        var selectedOutputUID: String?
        var launchAtLogin: Bool?
        var toggleShortcut: ToggleShortcutChoice?
        var pushShortcut: PushShortcutChoice?
        var ttsServer: TTSServerConfiguration?
        var dictationLocaleID: String?
        var historyRetention: HistoryRetention?
        var improvement: TextImprovementConfiguration?
        var glossary: [String]?
        var overlayPlacement: OverlayPlacement?
        var diarizationEnabled: Bool?
        var spokenCorrectionsEnabled: Bool?
        var condensedOutputEnabled: Bool?
        var quickDictationModel: TranscriptionModelChoice?
        var editWithVoiceModel: TranscriptionModelChoice?
        var meetingTranscriptModel: TranscriptionModelChoice?
        var ttsProvider: TTSProviderChoice?
    }

    private let defaults: UserDefaults
    private let key = "ToskVoice.Preferences.v1"
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let snapshot: Snapshot
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
        }
        let legacy = snapshot.profiles?.first(where: { $0.id == snapshot.selectedProfileID }) ?? snapshot.profiles?.first
        selectedInputUID = snapshot.selectedInputUID
        selectedOutputUID = snapshot.selectedOutputUID
        launchAtLogin = snapshot.launchAtLogin ?? false
        toggleShortcut = snapshot.toggleShortcut ?? .controlOptionSpace
        pushShortcut = snapshot.pushShortcut ?? .controlOptionD
        let server = snapshot.ttsServer ?? TTSServerConfiguration()
        ttsServer = server
        dictationLocaleID = snapshot.dictationLocaleID
            ?? (legacy?.speechMode == "german" ? "de-DE" : nil)
        historyRetention = snapshot.historyRetention ?? .hours24
        improvement = snapshot.improvement ?? TextImprovementConfiguration()
        glossary = snapshot.glossary
            ?? legacy?.glossary
            ?? ["Apos", "Epos", "Tobisk", "ToskVoice"]
        overlayPlacement = snapshot.overlayPlacement ?? legacy?.overlayPlacement ?? .menuBar
        diarizationEnabled = snapshot.diarizationEnabled ?? legacy?.diarizationEnabled ?? false
        spokenCorrectionsEnabled = snapshot.spokenCorrectionsEnabled ?? legacy?.spokenCorrectionsEnabled ?? true
        condensedOutputEnabled = snapshot.condensedOutputEnabled ?? legacy?.condensedOutputEnabled ?? false
        quickDictationModel = snapshot.quickDictationModel
            ?? (legacy?.speechMode == "automaticBilingual" ? .whisperBilingual : .appleSpeech)
        editWithVoiceModel = snapshot.editWithVoiceModel ?? .appleSpeech
        meetingTranscriptModel = snapshot.meetingTranscriptModel ?? .appleSpeech
        ttsProvider = snapshot.ttsProvider
            ?? (server.mode != .off ? (server.engine == .fish ? .fish : .xtts) : .builtInOnly)
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = Snapshot(
            selectedInputUID: selectedInputUID, selectedOutputUID: selectedOutputUID,
            launchAtLogin: launchAtLogin,
            toggleShortcut: toggleShortcut,
            pushShortcut: pushShortcut,
            ttsServer: ttsServer,
            dictationLocaleID: dictationLocaleID,
            historyRetention: historyRetention,
            improvement: improvement,
            glossary: glossary,
            overlayPlacement: overlayPlacement,
            diarizationEnabled: diarizationEnabled,
            spokenCorrectionsEnabled: spokenCorrectionsEnabled,
            condensedOutputEnabled: condensedOutputEnabled,
            quickDictationModel: quickDictationModel,
            editWithVoiceModel: editWithVoiceModel,
            meetingTranscriptModel: meetingTranscriptModel,
            ttsProvider: ttsProvider
        )
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL

    /// `directory` overrides the storage location (used by tests).
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToskVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    private var retentionProvider: (@MainActor () -> TimeInterval?)?
    private var pruneTimer: Timer?

    /// Wires the retention setting and starts periodic pruning. Entries older
    /// than the configured age are dropped on launch, on every new entry, and
    /// every few minutes while the app runs.
    func configureRetention(_ provider: @escaping @MainActor () -> TimeInterval?) {
        retentionProvider = provider
        prune()
        guard pruneTimer == nil else { return }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    func prune(now: Date = .now) {
        guard let maxAge = retentionProvider?() else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        let count = entries.count
        entries.removeAll { $0.createdAt < cutoff }
        if entries.count != count { persist() }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }
        prune()
        persist()
    }

    func update(_ entry: HistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        persist()
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
