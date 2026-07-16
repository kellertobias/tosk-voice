import AppKit

/// ToskVoice is a menu-bar accessory app, which keeps it out of the Dock and
/// the App Switcher. Document-style windows (Meeting Transcript, Text to
/// Speech) register here: while at least one is open the app becomes a
/// regular app so ⌘-Tab can reach it, and it returns to accessory when the
/// last one closes.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    func track(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        guard observers[identifier] == nil else { return }
        observers[identifier] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.untrack(identifier) }
        }
        if observers.count == 1 {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    private func untrack(_ identifier: ObjectIdentifier) {
        if let observer = observers.removeValue(forKey: identifier) {
            NotificationCenter.default.removeObserver(observer)
        }
        if observers.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
