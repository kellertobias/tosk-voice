import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ShortcutManager {
    var onToggle: (() -> Void)?
    var onPushStart: (() -> Void)?
    var onPushStop: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pushHeld = false
    private let preferences: PreferencesStore

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func start() {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let toggle = preferences.toggleShortcut
        let push = preferences.pushShortcut
        if flags == toggle.modifiers, event.keyCode == toggle.keyCode, event.type == .keyDown, !event.isARepeat {
            onToggle?()
        } else if event.keyCode == push.keyCode {
            if event.type == .keyDown, flags == push.modifiers, !pushHeld {
                pushHeld = true
                onPushStart?()
            } else if event.type == .keyUp, pushHeld {
                pushHeld = false
                onPushStop?()
            }
        }
    }
}
