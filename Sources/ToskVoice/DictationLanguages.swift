import Foundation
import Speech

/// The languages offered in the Quick Dictation overlay and Edit with Voice
/// window: every locale whose speech assets are installed in macOS, with
/// English (and the built-in profile languages) always present.
enum DictationLanguages {
    static func available() async -> [Locale] {
        var locales = await SpeechTranscriber.installedLocales
        for fallback in ["en-US", "de-DE"] where !locales.contains(where: { $0.identifier == fallback }) {
            locales.append(Locale(identifier: fallback))
        }
        return locales.sorted { label(for: $0).localizedCaseInsensitiveCompare(label(for: $1)) == .orderedAscending }
    }

    static func label(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    static func label(forIdentifier identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
