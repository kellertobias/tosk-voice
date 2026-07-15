import AppKit
import ApplicationServices
import Foundation
import os.log

private let deliveryLog = Logger(subsystem: "de.tobisk.toskvoice", category: "TextDelivery")

@MainActor
final class ExternalApplicationTracker: NSObject {
    static let shared = ExternalApplicationTracker()

    private(set) var lastExternalProcessID: pid_t?

    override private init() {
        super.init()
        record(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func targetProcessID() -> pid_t? {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let frontmost, frontmost != ProcessInfo.processInfo.processIdentifier {
            lastExternalProcessID = frontmost
        }
        return Self.preferredTarget(
            frontmost: frontmost,
            current: ProcessInfo.processInfo.processIdentifier,
            lastExternal: lastExternalProcessID
        )
    }

    nonisolated static func preferredTarget(
        frontmost: pid_t?,
        current: pid_t,
        lastExternal: pid_t?
    ) -> pid_t? {
        guard let frontmost else { return lastExternal }
        return frontmost == current ? lastExternal : frontmost
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        record(application?.processIdentifier)
    }

    private func record(_ processID: pid_t?) {
        guard let processID, processID != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalProcessID = processID
    }
}

@MainActor
final class CapturedTextTarget {
    private let processID: pid_t
    private let element: AXUIElement?
    private var listeningPlaceholderRange: CFRange?

    private init(processID: pid_t, element: AXUIElement?) {
        self.processID = processID
        self.element = element
    }

    static func capture() -> CapturedTextTarget? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedElement = focusedValue as! AXUIElement? {
            var focusedProcessID = pid_t()
            if AXUIElementGetPid(focusedElement, &focusedProcessID) == .success,
               focusedProcessID != ProcessInfo.processInfo.processIdentifier {
                enableAccessibilityTree(for: focusedProcessID)
                return CapturedTextTarget(processID: focusedProcessID, element: focusedElement)
            }
        }

        guard let processID = ExternalApplicationTracker.shared.targetProcessID() else { return nil }
        enableAccessibilityTree(for: processID)
        return CapturedTextTarget(processID: processID, element: focusedElement(of: processID))
    }

    /// Chromium-based apps (Electron: Obsidian, Teams, Claude Code, …) keep their
    /// accessibility tree disabled until a client opts in, so without this their
    /// focused text fields are invisible to the AX insertion paths.
    private static func enableAccessibilityTree(for processID: pid_t) {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func focusedElement(of processID: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as! AXUIElement?
    }

    /// Pasting is the primary delivery path: accessibility writes report success
    /// in apps that silently ignore them (terminals, some web editors), whereas a
    /// well-formed synthetic Cmd+V behaves exactly like the user pressing it.
    func insert(_ text: String) async -> Bool {
        if await paste(text, into: element ?? Self.focusedElement(of: processID)) { return true }
        deliveryLog.log("paste unavailable; falling back to accessibility insert")
        if let element, insertUsingAccessibility(text, into: element) { return true }
        let refreshed = Self.focusedElement(of: processID)
        if let refreshed, insertUsingAccessibility(text, into: refreshed) { return true }
        return false
    }

    private func insertUsingAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return true
        }
        if let selectedRange = selectedTextRange(of: element) {
            return replaceTextValue(in: element, range: selectedRange, with: text)
        }
        return false
    }

    var hasListeningPlaceholder: Bool {
        listeningPlaceholderRange != nil
    }

    /// Only the direct selected-text write is trusted here: value replacement and
    /// pasting can "succeed" in apps that never show the text, and a phantom
    /// placeholder would then reroute the final delivery to the wrong path.
    func beginListeningPlaceholder() -> Bool {
        guard AXIsProcessTrusted(),
              let element,
              let selectedRange = selectedTextRange(of: element),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                ListeningPlaceholder.text as CFString
              ) == .success else { return false }
        listeningPlaceholderRange = CFRange(
            location: selectedRange.location,
            length: (ListeningPlaceholder.text as NSString).length
        )
        return true
    }

    func replaceListeningPlaceholder(with text: String) async -> Bool {
        await replaceListeningPlaceholderValue(with: text, allowPaste: true)
    }

    func removeListeningPlaceholder() async {
        _ = await replaceListeningPlaceholderValue(with: "", allowPaste: false)
    }

    private func replaceListeningPlaceholderValue(with replacement: String, allowPaste: Bool) async -> Bool {
        guard let element, let range = listeningPlaceholderRange else { return false }
        defer { listeningPlaceholderRange = nil }

        if let value = textValue(of: element),
           !ListeningPlaceholder.matches(in: value, range: range) {
            return false
        }

        let selectedRangeSucceeded = selectTextRange(range, in: element)
        if selectedRangeSucceeded,
           AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                replacement as CFString
           ) == .success {
            return true
        }
        if replaceTextValue(
            in: element,
            range: range,
            with: replacement
        ) {
            return true
        }
        if allowPaste, selectedRangeSucceeded {
            return await paste(replacement, into: element)
        }
        return false
    }

    private func selectTextRange(_ range: CFRange, in element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success
    }

    private func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location != kCFNotFound else { return nil }
        return range
    }

    private func textValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private func replaceTextValue(
        in element: AXUIElement,
        range: CFRange,
        with replacement: String
    ) -> Bool {
        guard let currentValue = textValue(of: element),
              let updatedValue = TextRangeReplacement.replacing(
                range: range,
                in: currentValue,
                with: replacement
              ),
              AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                updatedValue as CFString
              ) == .success else { return false }

        var caretRange = CFRange(
            location: range.location + (replacement as NSString).length,
            length: 0
        )
        if let caretValue = AXValueCreate(.cfRange, &caretRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                caretValue
            )
        }
        return true
    }

    /// A synthetic Cmd+V always lands in the frontmost app's focused field, so the
    /// captured app is brought back to front and the captured field re-focused
    /// before posting, and the user is returned to their current app afterwards.
    /// If the captured app cannot be made frontmost the paste is aborted rather
    /// than typed into whatever the user is doing right now.
    private func paste(_ text: String, into field: AXUIElement?) async -> Bool {
        guard AXIsProcessTrusted() else {
            deliveryLog.log("paste skipped: process is not accessibility-trusted")
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let previousApplication = NSWorkspace.shared.frontmostApplication
        let needsActivation = previousApplication?.processIdentifier != processID
        if needsActivation {
            guard await activateTargetApplication() else {
                deliveryLog.log("paste skipped: could not bring pid \(self.processID) frontmost")
                return false
            }
        }
        if let field {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(50))
        }
        // The stop shortcut's modifiers are usually still held; combined with
        // the synthetic Cmd they would turn the paste into a different shortcut.
        await waitForModifierRelease()
        // Give the target time to observe the pasteboard change before Cmd+V.
        try? await Task.sleep(for: .milliseconds(100))

        // Mirror a real keypress the way VoiceInk and Maccy do: a private event
        // source so held physical keys don't bleed into the sequence, actual
        // Command key transitions rather than only event flags, and the
        // device-specific left-Command bit (0x8) for apps that inspect it.
        let source = CGEventSource(stateID: .privateState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let commandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            deliveryLog.log("paste failed: could not create keyboard events")
            return false
        }
        commandDown.flags = commandFlags
        vDown.flags = commandFlags
        vUp.flags = commandFlags
        commandUp.flags = []
        for event in [commandDown, vDown, vUp, commandUp] {
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(10))
        }
        deliveryLog.log("posted Cmd+V into pid \(self.processID)")

        if needsActivation,
           let previousApplication,
           previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            try? await Task.sleep(for: .milliseconds(250))
            previousApplication.activate()
        }
        return true
    }

    private func activateTargetApplication() async -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processID) else { return false }
        application.activate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processID { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func waitForModifierRelease() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        while clock.now < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}

enum ListeningPlaceholder {
    static let text = "[Listening]"

    static func matches(in value: String, range: CFRange) -> Bool {
        guard range.location >= 0, range.length >= 0 else { return false }
        let string = value as NSString
        guard range.location <= string.length,
              range.length <= string.length - range.location else { return false }
        return string.substring(
            with: NSRange(location: range.location, length: range.length)
        ) == text
    }
}

enum TextRangeReplacement {
    static func replacing(range: CFRange, in value: String, with replacement: String) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let result = NSMutableString(string: value)
        guard range.location <= result.length,
              range.length <= result.length - range.location else { return nil }
        result.replaceCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: replacement
        )
        return result as String
    }
}

enum TextDelivery {
    static func appendMarkdown(_ text: String, bookmark: Data) throws -> String {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let block = "\n\n## \(formatter.string(from: .now))\n\n\(text)\n"
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                if !FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    try Data().write(to: coordinatedURL)
                }
                let handle = try FileHandle(forWritingTo: coordinatedURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(block.utf8))
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        return url.path
    }
}
