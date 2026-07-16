import AppKit
import FoundationModels
import SwiftUI
import UniformTypeIdentifiers

struct MeetingQAEntry: Identifiable, Sendable {
    let id = UUID()
    let question: String
    var answer: String
    var isPending: Bool
}

@MainActor
final class MeetingController: ObservableObject {
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var status = "Ready"
    @Published var micLevel: Float = 0
    @Published var remoteLevel: Float = 0
    @Published var segments: [MeetingSegment] = []
    @Published var micVolatile = ""
    @Published var remoteVolatile = ""
    @Published var availableApps: [TappableApp] = []
    @Published var selectedBundleID: String?
    @Published var question = ""
    @Published var qaEntries: [MeetingQAEntry] = []
    @Published var isAnswering = false

    private(set) var sessionStart: Date?
    private var savedSegmentCount = 0

    private let session = MeetingSession()
    private let preferences: PreferencesStore
    private let profileProvider: @MainActor () -> DictationProfile

    init(preferences: PreferencesStore, profileProvider: @escaping @MainActor () -> DictationProfile) {
        self.preferences = preferences
        self.profileProvider = profileProvider
    }

    var hasUnsavedContent: Bool { segments.count > savedSegmentCount }

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

    func togglePause() {
        guard isRunning else { return }
        isPaused.toggle()
        session.isPaused = isPaused
        if isPaused {
            micLevel = 0
            remoteLevel = 0
            micVolatile = ""
            remoteVolatile = ""
        }
        status = isPaused ? "Paused" : "Listening"
    }

    func start() async {
        guard !isRunning else { return }
        segments = []
        qaEntries = []
        savedSegmentCount = 0
        micVolatile = ""
        remoteVolatile = ""
        isPaused = false
        session.isPaused = false
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
                        guard self?.isPaused != true else { return }
                        switch speaker {
                        case .me: self?.micLevel = level
                        case .remote: self?.remoteLevel = level
                        }
                    }
                )
            )
            sessionStart = Date()
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
        isPaused = false
        micVolatile = ""
        remoteVolatile = ""
        micLevel = 0
        remoteLevel = 0
        status = "Ready"
    }

    // MARK: - Transcript export

    var transcriptMarkdown: String {
        let header = "# Meeting Transcript — \(Self.dateFormatter.string(from: sessionStart ?? Date()))\n"
        let body = segments.map { segment in
            "**\(segment.speaker.rawValue)** (\(Self.timeFormatter.string(from: segment.capturedAt))): \(segment.text)"
        }.joined(separator: "\n\n")
        return header + "\n" + body + "\n"
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptMarkdown, forType: .string)
    }

    /// Shows a save panel and writes the transcript as Markdown.
    /// Returns true when the file was written, false when cancelled or failed.
    @discardableResult
    func saveTranscript(in window: NSWindow?) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Meeting \(Self.fileNameFormatter.string(from: sessionStart ?? Date())).md"
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            response = panel.runModal()
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return false }
        do {
            try transcriptMarkdown.write(to: url, atomically: true, encoding: .utf8)
            savedSegmentCount = segments.count
            status = "Saved to \(url.lastPathComponent)"
            return true
        } catch {
            status = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Transcript Q&A

    func ask() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isAnswering, !segments.isEmpty else { return }
        question = ""
        let entry = MeetingQAEntry(question: asked, answer: "", isPending: true)
        qaEntries.append(entry)
        isAnswering = true
        let transcript = transcriptMarkdown
        Task { [weak self] in
            let answer = await Self.answer(question: asked, transcript: transcript)
            guard let self else { return }
            if let index = self.qaEntries.firstIndex(where: { $0.id == entry.id }) {
                self.qaEntries[index].answer = answer
                self.qaEntries[index].isPending = false
            }
            self.isAnswering = false
        }
    }

    private static func answer(question: String, transcript: String) async -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            return "Apple Intelligence is unavailable on this Mac, so transcript questions cannot be answered."
        }
        let session = LanguageModelSession(instructions: """
        You answer questions about a meeting transcript. The transcript lists \
        timestamped statements labeled with their speaker ("Me" is the local user, \
        "Remote" covers the other participants). Answer only from the transcript; \
        say plainly when it does not contain the answer. Quote the relevant speaker \
        where helpful. Answer in the language of the question.
        """)
        do {
            let response = try await session.respond(to: "TRANSCRIPT:\n\(transcript)\n\nQUESTION: \(question)")
            return response.content
        } catch {
            return "The question could not be answered: \(error.localizedDescription)"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()
}

@MainActor
final class MeetingWindowController: NSObject, NSWindowDelegate {
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
        window.setContentSize(NSSize(width: 1000, height: 660))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard controller.hasUnsavedContent else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the meeting transcript?"
        alert.informativeText = "The transcript contains unsaved content. It will be discarded when the window closes."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return controller.saveTranscript(in: sender)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Task { await controller.stop() }
    }
}

private struct MeetingView: View {
    @ObservedObject var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 20) {
                LevelMeter(label: "Mic (Me)", systemImage: "mic.fill", level: controller.micLevel, tint: MeetingSpeaker.me.tint)
                LevelMeter(label: "Remote", systemImage: "person.2.wave.2.fill", level: controller.remoteLevel, tint: MeetingSpeaker.remote.tint)
            }
            Divider()
            HSplitView {
                transcriptColumn
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                qaColumn
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 480, maxHeight: .infinity)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 520)
    }

    private var header: some View {
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
            if controller.isRunning {
                Button(controller.isPaused ? "Resume" : "Pause") { controller.togglePause() }
            }
            Button(controller.isRunning ? "Stop" : "Start") { controller.toggle() }
                .buttonStyle(.borderedProminent)
                .tint(controller.isRunning ? .red : .accentColor)
        }
    }

    private var transcriptColumn: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 8) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.segments) { segment in
                            SegmentRow(segment: segment).id(segment.id)
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

                TimelineRail(segments: controller.segments, sessionStart: controller.sessionStart) { segmentID in
                    withAnimation { proxy.scrollTo(segmentID, anchor: .center) }
                }
                .frame(width: 26)
            }
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var qaColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask the Transcript", systemImage: "sparkles")
                .font(.callout.bold())
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if controller.qaEntries.isEmpty {
                            Text("Ask things like “What did Remote say about the deadline?” The answer uses only this transcript and stays on this Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(controller.qaEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.question)
                                    .font(.callout.bold())
                                if entry.isPending {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(entry.answer)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            .id(entry.id)
                        }
                    }
                    .padding(2)
                }
                .onChange(of: controller.qaEntries.last?.answer) {
                    if let last = controller.qaEntries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack(spacing: 8) {
                TextField("Ask about the meeting…", text: $controller.question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.ask() }
                Button {
                    controller.ask()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(controller.question.trimmingCharacters(in: .whitespaces).isEmpty || controller.isAnswering || controller.segments.isEmpty)
            }
        }
        .padding(.leading, 10)
    }

    private var footer: some View {
        HStack {
            Button("Copy Transcript") { controller.copyTranscript() }
                .disabled(controller.segments.isEmpty)
            Button("Save Transcript…") { controller.saveTranscript(in: NSApp.keyWindow) }
                .disabled(controller.segments.isEmpty)
            Spacer()
            Text("\(controller.segments.count) segments").font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension MeetingSpeaker {
    var tint: Color {
        switch self {
        case .me: .blue
        case .remote: .green
        }
    }
}

/// A Time Machine-style timeline beside the transcript: each segment is a
/// tick positioned by its capture time and colored by speaker. Clicking a
/// tick jumps the transcript to that segment.
private struct TimelineRail: View {
    let segments: [MeetingSegment]
    let sessionStart: Date?
    let onJump: (UUID) -> Void

    var body: some View {
        GeometryReader { geometry in
            let span = timeSpan
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.quaternary.opacity(0.6))
                    .frame(width: 3)
                    .frame(maxWidth: .infinity)
                ForEach(segments) { segment in
                    let fraction = span > 0
                        ? segment.capturedAt.timeIntervalSince(start) / span
                        : 0
                    Capsule()
                        .fill(segment.speaker.tint)
                        .frame(width: 14, height: 5)
                        .contentShape(Rectangle().inset(by: -4))
                        .position(
                            x: geometry.size.width / 2,
                            y: 6 + CGFloat(fraction) * max(0, geometry.size.height - 12)
                        )
                        .onTapGesture { onJump(segment.id) }
                        .help("\(segment.speaker.rawValue): \(String(segment.text.prefix(80)))")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var start: Date {
        sessionStart ?? segments.first?.capturedAt ?? Date()
    }

    private var timeSpan: TimeInterval {
        guard let last = segments.last else { return 0 }
        return max(1, last.capturedAt.timeIntervalSince(start))
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
                    .foregroundStyle(segment.speaker.tint)
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
                .foregroundStyle(speaker.tint.opacity(0.6))
            Text(text)
                .font(.body.italic())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
