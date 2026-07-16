import AppKit
import SwiftUI

@MainActor
final class MeetingController: ObservableObject {
    @Published var isRunning = false
    @Published var status = "Ready"
    @Published var micLevel: Float = 0
    @Published var remoteLevel: Float = 0
    @Published var segments: [MeetingSegment] = []
    @Published var micVolatile = ""
    @Published var remoteVolatile = ""
    @Published var availableApps: [TappableApp] = []
    @Published var selectedBundleID: String?

    private let session = MeetingSession()
    private let preferences: PreferencesStore
    private let profileProvider: @MainActor () -> DictationProfile

    init(preferences: PreferencesStore, profileProvider: @escaping @MainActor () -> DictationProfile) {
        self.preferences = preferences
        self.profileProvider = profileProvider
    }

    func refreshApps() {
        availableApps = SystemAudioTap.availableApps()
        if let selectedBundleID, !availableApps.contains(where: { $0.bundleID == selectedBundleID }) {
            self.selectedBundleID = nil
        }
        if selectedBundleID == nil {
            let conferencing = ["com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos", "com.cisco.webexmeetingsapp", "com.hnc.Discord", "com.google.Chrome", "com.apple.Safari"]
            selectedBundleID = conferencing.compactMap { id in availableApps.first { $0.bundleID == id }?.bundleID }.first
        }
    }

    func toggle() {
        Task { isRunning ? await stop() : await start() }
    }

    func start() async {
        guard !isRunning else { return }
        segments = []
        micVolatile = ""
        remoteVolatile = ""
        status = "Starting…"
        let profile = profileProvider()
        let target: SystemAudioTap.Target
        if let bundleID = selectedBundleID, let app = availableApps.first(where: { $0.bundleID == bundleID }) {
            target = .app(app)
        } else {
            target = .allProcesses
        }
        do {
            try await session.start(
                target: target,
                locale: profile.speechMode.locale,
                glossary: profile.glossary,
                inputUID: preferences.selectedInputUID,
                callbacks: .init(
                    onSegment: { [weak self] segment in
                        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        self?.segments.append(segment)
                    },
                    onVolatile: { [weak self] speaker, text in
                        switch speaker {
                        case .me: self?.micVolatile = text
                        case .remote: self?.remoteVolatile = text
                        }
                    },
                    onLevel: { [weak self] speaker, level in
                        switch speaker {
                        case .me: self?.micLevel = level
                        case .remote: self?.remoteLevel = level
                        }
                    }
                )
            )
            isRunning = true
            status = "Listening"
        } catch {
            status = error.localizedDescription
        }
    }

    func stop() async {
        guard isRunning else { return }
        status = "Finishing…"
        await session.stop()
        isRunning = false
        micVolatile = ""
        remoteVolatile = ""
        micLevel = 0
        remoteLevel = 0
        status = "Ready"
    }

    var transcriptMarkdown: String {
        segments.map { segment in
            "**\(segment.speaker.rawValue)** (\(Self.timeFormatter.string(from: segment.capturedAt))): \(segment.text)"
        }.joined(separator: "\n\n")
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptMarkdown, forType: .string)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

@MainActor
final class MeetingWindowController {
    private var window: NSWindow?
    private let controller: MeetingController

    init(preferences: PreferencesStore, profileProvider: @escaping @MainActor () -> DictationProfile) {
        controller = MeetingController(preferences: preferences, profileProvider: profileProvider)
    }

    func show() {
        controller.refreshApps()
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: MeetingView(controller: controller))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ToskVoice — Meeting Transcript"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 620))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct MeetingView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("Capture", selection: $controller.selectedBundleID) {
                    Text("All system audio").tag(String?.none)
                    ForEach(controller.availableApps) { app in
                        Text(app.name).tag(String?.some(app.bundleID))
                    }
                }
                .frame(maxWidth: 320)
                .disabled(controller.isRunning)
                Button("Refresh") { controller.refreshApps() }
                    .disabled(controller.isRunning)
                Spacer()
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
                Button(controller.isRunning ? "Stop" : "Start") { controller.toggle() }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isRunning ? .red : .accentColor)
            }

            HStack(spacing: 20) {
                LevelMeter(label: "Mic (Me)", systemImage: "mic.fill", level: controller.micLevel, tint: .blue)
                LevelMeter(label: "Remote", systemImage: "person.2.wave.2.fill", level: controller.remoteLevel, tint: .green)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.segments) { segment in
                            SegmentRow(segment: segment)
                        }
                        if !controller.remoteVolatile.isEmpty {
                            VolatileRow(speaker: .remote, text: controller.remoteVolatile)
                        }
                        if !controller.micVolatile.isEmpty {
                            VolatileRow(speaker: .me, text: controller.micVolatile)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: controller.segments.count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: controller.micVolatile) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: controller.remoteVolatile) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button("Copy Transcript") { controller.copyTranscript() }
                    .disabled(controller.segments.isEmpty)
                Spacer()
                Text("\(controller.segments.count) segments").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }
}

private struct LevelMeter: View {
    let label: String
    let systemImage: String
    let level: Float
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: systemImage)
                .font(.callout)
                .frame(width: 110, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(4, geometry.size.width * CGFloat(min(1, level))))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 10)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SegmentRow: View {
    let segment: MeetingSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(segment.speaker.rawValue)
                    .font(.caption.bold())
                    .foregroundStyle(segment.speaker == .me ? Color.blue : Color.green)
                Text(segment.capturedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VolatileRow: View {
    let speaker: MeetingSpeaker
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(speaker.rawValue)
                .font(.caption.bold())
                .foregroundStyle((speaker == .me ? Color.blue : Color.green).opacity(0.6))
            Text(text)
                .font(.body.italic())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
