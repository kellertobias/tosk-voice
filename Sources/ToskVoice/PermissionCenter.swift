import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var microphoneGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var accessibilityGranted = false

    init() {
        refresh()
    }

    func refresh() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        inputMonitoringGranted = CGPreflightListenEventAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refresh()
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
        if !inputMonitoringGranted {
            openPrivacySettings("Privacy_ListenEvent")
        }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
