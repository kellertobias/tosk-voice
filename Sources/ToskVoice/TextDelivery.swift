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
    private let processID: pid_t
    private let element: AXUIElement?
    private var listeningPlaceholderRange: CFRange?

    private init(processID: pid_t, element: AXUIElement?) {
        self.processID = processID
        self.element = element
    }

    @MainActor
    static func capture() -> CapturedTextTarget? {
        guard let processID = ExternalApplicationTracker.shared.targetProcessID() else { return nil }
        let application = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
        return CapturedTextTarget(processID: processID, element: result == .success ? (value as! AXUIElement?) : nil)
    }

    func insert(_ text: String) -> Bool {
        if let element {
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            if result == .success { return true }
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

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            ListeningPlaceholder.text as CFString
        )
        guard result == .success else { return false }
        listeningPlaceholderRange = CFRange(
            location: selectedRange.location,
            length: (ListeningPlaceholder.text as NSString).length
        )
        return true
    }

    func replaceListeningPlaceholder(with text: String) -> Bool {
        replaceListeningPlaceholderValue(with: text)
    }

    func removeListeningPlaceholder() {
        _ = replaceListeningPlaceholderValue(with: "")
    }

    private func replaceListeningPlaceholderValue(with replacement: String) -> Bool {
        guard let element, let range = listeningPlaceholderRange else { return false }
        defer { listeningPlaceholderRange = nil }

        if let value = textValue(of: element),
           !ListeningPlaceholder.matches(in: value, range: range) {
            return false
        }

        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
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

    private func paste(_ text: String) -> Bool {
        // Posting Command-V is controlled by Accessibility. Without this
        // preflight, CGEvent silently drops the keystrokes and we would report
        // a successful insertion even though nothing reached the target app.
        guard CGPreflightPostEventAccess() else { return false }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processID)
        up.postToPid(processID)

        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pasteboard.clearContents()
                let items = previous.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                pasteboard.writeObjects(items)
            }
        }
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
