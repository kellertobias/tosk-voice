import AppKit
import Foundation

enum DictationState: Equatable, Sendable {
    case idle
    case preparing
    case listening
    case correcting
    case finalizing
    case committed
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Ready"
        case .preparing: "Preparing…"
        case .listening: "Listening"
        case .correcting: "Applying correction…"
        case .finalizing: "Finishing…"
        case .committed: "Inserted"
        case .failed(let message): message
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .listening, .correcting, .finalizing: true
        default: false
        }
    }
}

enum SpeechMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case english
    case german
    case automaticBilingual

    var id: String { rawValue }
    var label: String {
        switch self {
        case .english: "English"
        case .german: "German"
        case .automaticBilingual: "English + German (model pack)"
        }
    }
    var locale: Locale {
        switch self {
        case .german: Locale(identifier: "de-DE")
        default: Locale(identifier: "en-US")
        }
    }
}

enum OverlayPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case menuBar
    case topLeft
    case topCenter
    case topRight
    case center
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }
    var label: String {
        switch self {
        case .menuBar: "Below Menu Bar"
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .center: "Center"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// An OpenAI-compatible speech endpoint (`POST …/v1/audio/speech`) serving
/// models such as XTTS v2 (xtts-api-server, openedai-speech) or Fish-Speech.
/// Precision (FP8/FP16) is a launch option of that server, not of the client.
enum TTSServerAPIStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// POST /v1/audio/speech with {model, input, voice} — openedai-speech,
    /// xtts-api-server wrappers, mlx-audio, OpenAI, …
    case openAI
    /// POST /v1/tts with {text, format, reference_id} — Fish-Speech's stock
    /// api_server, which does not implement the OpenAI route.
    case fishSpeech

    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAI: "OpenAI-compatible"
        case .fishSpeech: "Fish-Speech native"
        }
    }
}

struct TTSServerConfiguration: Codable, Equatable, Sendable {
    var baseURL: String = ""
    var apiStyle: TTSServerAPIStyle = .openAI
    var model: String = "tts-1"
    var voice: String = ""
    var apiKey: String = ""
    /// Shell command that launches a local server for this endpoint
    /// (managed-server mode); empty when the server is managed externally.
    var managedCommand: String = ""
    /// Launch the managed server automatically when ToskVoice starts.
    var autoStart: Bool = false

    init() {}

    /// Tolerant decoding so preferences saved by older builds (without newer
    /// fields such as apiStyle) keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiStyle = try container.decodeIfPresent(TTSServerAPIStyle.self, forKey: .apiStyle) ?? .openAI
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "tts-1"
        voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        managedCommand = try container.decodeIfPresent(String.self, forKey: .managedCommand) ?? ""
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }

    var isConfigured: Bool { !baseURL.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Root URL used to detect that the (managed) server is accepting
    /// connections; any HTTP response counts.
    var healthProbeURL: URL? {
        guard let endpoint = speechEndpoint,
              let scheme = endpoint.scheme, let host = endpoint.host else { return nil }
        var root = "\(scheme)://\(host)"
        if let port = endpoint.port { root += ":\(port)" }
        return URL(string: root + "/")
    }

    /// Accepts a bare host, a host with /v1, or a full endpoint path.
    var speechEndpoint: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        if !base.contains("://") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        let path = apiStyle == .fishSpeech ? "/tts" : "/audio/speech"
        if base.hasSuffix(path) { return URL(string: base) }
        if base.hasSuffix("/v1") { return URL(string: base + path) }
        return URL(string: base + "/v1" + path)
    }
}

enum DestinationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case focusedField
    case markdown

    var id: String { rawValue }
    var label: String { self == .focusedField ? "Focused Text Field" : "Markdown File" }
}

enum ToggleShortcutChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case controlOptionSpace
    case controlShiftSpace
    case commandShiftSpace
    case controlOptionS

    var id: String { rawValue }
    var label: String {
        switch self {
        case .controlOptionSpace: "⌃⌥Space"
        case .controlShiftSpace: "⌃⇧Space"
        case .commandShiftSpace: "⌘⇧Space"
        case .controlOptionS: "⌃⌥S"
        }
    }
    var keyCode: UInt16 { self == .controlOptionS ? 1 : 49 }
    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .controlOptionSpace, .controlOptionS: [.control, .option]
        case .controlShiftSpace: [.control, .shift]
        case .commandShiftSpace: [.command, .shift]
        }
    }
}

enum PushShortcutChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case controlOptionD
    case controlOptionF
    case controlShiftD

    var id: String { rawValue }
    var label: String {
        switch self {
        case .controlOptionD: "⌃⌥D"
        case .controlOptionF: "⌃⌥F"
        case .controlShiftD: "⌃⇧D"
        }
    }
    var keyCode: UInt16 {
        switch self { case .controlOptionF: 3; default: 2 }
    }
    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .controlOptionD, .controlOptionF: [.control, .option]
        case .controlShiftD: [.control, .shift]
        }
    }
}

struct DictationProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var speechMode: SpeechMode
    var destination: DestinationKind
    var markdownBookmark: Data?
    var markdownDisplayPath: String?
    var overlayPlacement: OverlayPlacement
    var glossary: [String]
    var diarizationEnabled: Bool
    var spokenCorrectionsEnabled: Bool? = true
    var condensedOutputEnabled: Bool? = false

    var usesSpokenCorrections: Bool { spokenCorrectionsEnabled ?? true }
    var producesCondensedOutput: Bool { condensedOutputEnabled ?? false }

    static let standard = DictationProfile(
        id: UUID(),
        name: "Quick Dictation",
        speechMode: .english,
        destination: .focusedField,
        markdownBookmark: nil,
        markdownDisplayPath: nil,
        overlayPlacement: .menuBar,
        glossary: ["Apos", "Epos", "Tobisk", "ToskVoice"],
        diarizationEnabled: false,
        spokenCorrectionsEnabled: true,
        condensedOutputEnabled: false
    )
}

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: UInt32
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
}

struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    let timestamp: Date
    var speaker: String?

    init(text: String, timestamp: Date = .now, speaker: String? = nil) {
        id = UUID()
        self.text = text
        self.timestamp = timestamp
        self.speaker = speaker
    }
}

struct TimedUtterance: Equatable, Sendable {
    var text: String
    var start: Float
    var end: Float
}

struct TranscriptLedger: Equatable, Sendable {
    private(set) var segments: [TranscriptSegment] = []
    private var undoStack: [[TranscriptSegment]] = []

    var text: String {
        segments.map { segment in
            if let speaker = segment.speaker { return "\(speaker): \(segment.text)" }
            return segment.text
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func append(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        segments.append(TranscriptSegment(text: cleaned))
    }

    mutating func assignSpeakers(_ speakers: [String?]) {
        for index in segments.indices where index < speakers.count {
            segments[index].speaker = speakers[index]
        }
    }

    @discardableResult
    mutating func applyStandaloneCommand(_ utterance: String) -> Bool {
        let normalized = utterance
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        if ["strike that", "delete that", "streich das", "lösche das"].contains(normalized) {
            guard !segments.isEmpty else { return true }
            checkpoint()
            segments.removeLast()
            return true
        }

        if ["undo sentence", "delete sentence", "satz löschen", "letzten satz löschen"].contains(normalized) {
            guard !segments.isEmpty else { return true }
            checkpoint()
            var combined = text
            if let boundary = combined.dropLast().lastIndex(where: { ".!?".contains($0) }) {
                combined = String(combined[...boundary]).trimmingCharacters(in: .whitespaces)
            } else {
                combined = ""
            }
            segments = combined.isEmpty ? [] : [TranscriptSegment(text: combined)]
            return true
        }

        if ["undo correction", "restore that", "korrektur rückgängig", "wiederherstellen"].contains(normalized) {
            if let previous = undoStack.popLast() { segments = previous }
            return true
        }

        let patterns = [
            #"(?i)^replace\s+(.+?)\s+with\s+(.+?)[.!?]?$"#,
            #"(?i)^ersetze\s+(.+?)\s+durch\s+(.+?)[.!?]?$"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = utterance as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = expression.firstMatch(in: utterance, range: range), match.numberOfRanges == 3 else { continue }
            let old = ns.substring(with: match.range(at: 1))
            let new = ns.substring(with: match.range(at: 2))
            let current = text
            guard current.range(of: old, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return true }
            checkpoint()
            let revised = current.replacingOccurrences(of: old, with: new, options: [.caseInsensitive, .diacriticInsensitive])
            segments = [TranscriptSegment(text: revised)]
            return true
        }

        return false
    }

    mutating func replaceAll(with text: String) {
        checkpoint()
        segments = text.isEmpty ? [] : [TranscriptSegment(text: text)]
    }

    private mutating func checkpoint() {
        undoStack.append(segments)
        if undoStack.count > 20 { undoStack.removeFirst() }
    }
}

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    var text: String
    let profileName: String
    let destinationDescription: String

    init(text: String, profileName: String, destinationDescription: String) {
        id = UUID()
        createdAt = .now
        self.text = text
        self.profileName = profileName
        self.destinationDescription = destinationDescription
    }
}
