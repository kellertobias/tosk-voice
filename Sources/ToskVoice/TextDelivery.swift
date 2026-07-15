import AppKit
import ApplicationServices
import Foundation

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

final class CapturedTextTarget: @unchecked Sendable {
    private let element: AXUIElement?
    private var listeningPlaceholderRange: CFRange?

    private init(element: AXUIElement?) {
        self.element = element
    }

    @MainActor
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
                return CapturedTextTarget(element: focusedElement)
            }
        }

        guard let processID = ExternalApplicationTracker.shared.targetProcessID() else { return nil }
        let application = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
        return CapturedTextTarget(element: result == .success ? (value as! AXUIElement?) : nil)
    }

    func insert(_ text: String) -> Bool {
        if let element {
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            if result == .success { return true }
            if let selectedRange = selectedTextRange(of: element),
               replaceTextValue(in: element, range: selectedRange, with: text) {
                return true
            }
        }
        return paste(text)
    }

    var hasListeningPlaceholder: Bool {
        listeningPlaceholderRange != nil
    }

    func beginListeningPlaceholder() -> Bool {
        guard AXIsProcessTrusted(),
              let element,
              let selectedRange = selectedTextRange(of: element) else { return false }

        var inserted = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            ListeningPlaceholder.text as CFString
        ) == .success || replaceTextValue(
            in: element,
            range: selectedRange,
            with: ListeningPlaceholder.text
        )
        if !inserted, selectTextRange(selectedRange, in: element) {
            inserted = paste(ListeningPlaceholder.text)
        }
        guard inserted else { return false }
        listeningPlaceholderRange = CFRange(
            location: selectedRange.location,
            length: (ListeningPlaceholder.text as NSString).length
        )
        return true
    }

    func replaceListeningPlaceholder(with text: String) -> Bool {
        replaceListeningPlaceholderValue(with: text, allowPaste: true)
    }

    func removeListeningPlaceholder() {
        _ = replaceListeningPlaceholderValue(with: "", allowPaste: false)
    }

    private func replaceListeningPlaceholderValue(with replacement: String, allowPaste: Bool) -> Bool {
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
        return allowPaste && selectedRangeSucceeded && paste(replacement)
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

    private func paste(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
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
