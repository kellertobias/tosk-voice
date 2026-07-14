import Foundation

@MainActor
final class PreferencesStore: ObservableObject {
    @Published var profiles: [DictationProfile] { didSet { save() } }
    @Published var selectedProfileID: UUID { didSet { save() } }
    @Published var selectedInputUID: String? { didSet { save() } }
    @Published var selectedOutputUID: String? { didSet { save() } }
    @Published var launchAtLogin: Bool { didSet { save() } }
    @Published var toggleShortcut: ToggleShortcutChoice { didSet { save() } }
    @Published var pushShortcut: PushShortcutChoice { didSet { save() } }

    private struct Snapshot: Codable {
        var profiles: [DictationProfile]
        var selectedProfileID: UUID
        var selectedInputUID: String?
        var selectedOutputUID: String?
        var launchAtLogin: Bool
        var toggleShortcut: ToggleShortcutChoice?
        var pushShortcut: PushShortcutChoice?
    }

    private let defaults = UserDefaults.standard
    private let key = "ToskVoice.Preferences.v1"
    private var isLoading = true

    init() {
        if let data = defaults.data(forKey: key), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), !snapshot.profiles.isEmpty {
            profiles = snapshot.profiles
            selectedProfileID = snapshot.selectedProfileID
            selectedInputUID = snapshot.selectedInputUID
            selectedOutputUID = snapshot.selectedOutputUID
            launchAtLogin = snapshot.launchAtLogin
            toggleShortcut = snapshot.toggleShortcut ?? .controlOptionSpace
            pushShortcut = snapshot.pushShortcut ?? .controlOptionD
        } else {
            let profile = DictationProfile.standard
            profiles = [profile]
            selectedProfileID = profile.id
            selectedInputUID = nil
            selectedOutputUID = nil
            launchAtLogin = false
            toggleShortcut = .controlOptionSpace
            pushShortcut = .controlOptionD
        }
        isLoading = false
    }

    var selectedProfile: DictationProfile {
        get { profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0] }
        set {
            if let index = profiles.firstIndex(where: { $0.id == newValue.id }) {
                profiles[index] = newValue
            }
        }
    }

    func addProfile() {
        let profile = DictationProfile(
            id: UUID(), name: "New Profile", speechMode: .english, destination: .focusedField,
            markdownBookmark: nil, markdownDisplayPath: nil, overlayPlacement: .menuBar,
            glossary: [], diarizationEnabled: false
        )
        profiles.append(profile)
        selectedProfileID = profile.id
    }

    func deleteSelectedProfile() {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == selectedProfileID }
        selectedProfileID = profiles[0].id
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = Snapshot(
            profiles: profiles, selectedProfileID: selectedProfileID,
            selectedInputUID: selectedInputUID, selectedOutputUID: selectedOutputUID,
            launchAtLogin: launchAtLogin,
            toggleShortcut: toggleShortcut,
            pushShortcut: pushShortcut
        )
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToskVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }
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
