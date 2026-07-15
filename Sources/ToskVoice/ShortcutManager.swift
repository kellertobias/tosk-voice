import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

@MainActor
final class ShortcutManager {
    var onToggle: (() -> Void)?
    var onPushStart: (() -> Void)?
    var onPushStop: (() -> Void)?

    private nonisolated enum HotKey: UInt32 {
        case toggle = 1
        case pushToTalk = 2
    }

    private nonisolated static let signature: OSType = 0x54534B56 // TSKV
    private var eventHandler: EventHandlerRef?
    private var toggleHotKey: EventHotKeyRef?
    private var pushHotKey: EventHotKeyRef?
    private var shortcutObservation: AnyCancellable?
    private var pushHeld = false
    private let preferences: PreferencesStore

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func start() {
        installEventHandler()
        registerHotKeys()
        shortcutObservation = Publishers.CombineLatest(
            preferences.$toggleShortcut,
            preferences.$pushShortcut
        )
        .dropFirst()
        .sink { [weak self] _ in
            self?.registerHotKeys()
        }
    }

    func stop() {
        shortcutObservation = nil
        unregisterHotKeys()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleCarbonEvent,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func registerHotKeys() {
        unregisterHotKeys()
        let toggle = preferences.toggleShortcut
        let push = preferences.pushShortcut
        RegisterEventHotKey(
            UInt32(toggle.keyCode),
            carbonModifiers(toggle.modifiers),
            EventHotKeyID(signature: Self.signature, id: HotKey.toggle.rawValue),
            GetApplicationEventTarget(),
            0,
            &toggleHotKey
        )
        RegisterEventHotKey(
            UInt32(push.keyCode),
            carbonModifiers(push.modifiers),
            EventHotKeyID(signature: Self.signature, id: HotKey.pushToTalk.rawValue),
            GetApplicationEventTarget(),
            0,
            &pushHotKey
        )
    }

    private func unregisterHotKeys() {
        if let toggleHotKey { UnregisterEventHotKey(toggleHotKey) }
        if let pushHotKey { UnregisterEventHotKey(pushHotKey) }
        toggleHotKey = nil
        pushHotKey = nil
        pushHeld = false
    }

    private func carbonModifiers(_ modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private func handle(_ hotKey: HotKey, pressed: Bool) {
        switch hotKey {
        case .toggle:
            if pressed { onToggle?() }
        case .pushToTalk:
            if pressed, !pushHeld {
                pushHeld = true
                onPushStart?()
            } else if !pressed, pushHeld {
                pushHeld = false
                onPushStop?()
            }
        }
    }

    private nonisolated(unsafe) static let handleCarbonEvent: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr,
              identifier.signature == signature,
              let hotKey = HotKey(rawValue: identifier.id) else {
            return OSStatus(eventNotHandledErr)
        }
        let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        let contextAddress = UInt(bitPattern: context)
        return MainActor.assumeIsolated {
            guard let actorContext = UnsafeMutableRawPointer(bitPattern: contextAddress) else {
                return OSStatus(eventNotHandledErr)
            }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(actorContext).takeUnretainedValue()
            manager.handle(hotKey, pressed: pressed)
            return noErr
        }
    }
}
