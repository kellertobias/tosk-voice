import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: HistoryView(store: model.history))
        let window = NSWindow(contentViewController: controller)
        window.title = "ToskVoice History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            List(store.entries, selection: $selectedID) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text).lineLimit(2)
                    Text(entry.createdAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(entry.id)
            }
            .overlay {
                if store.entries.isEmpty { ContentUnavailableView("No Dictations", systemImage: "waveform", description: Text("Completed transcripts appear here.")) }
            }
        } detail: {
            if let id = selectedID, let entry = store.entries.first(where: { $0.id == id }) {
                HistoryDetail(entry: entry, store: store)
            } else {
                ContentUnavailableView("Select a Dictation", systemImage: "text.quote")
            }
        }
        .toolbar {
            Button("Clear History", role: .destructive) { store.clear() }
                .disabled(store.entries.isEmpty)
        }
    }
}

private struct HistoryDetail: View {
    @State var entry: HistoryEntry
    @ObservedObject var store: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.profileName).font(.headline)
                    Text(entry.destinationDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                }
                Button("Save") { store.update(entry) }.buttonStyle(.borderedProminent)
                Button("Delete", role: .destructive) { store.delete(entry) }
            }
            TextEditor(text: $entry.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(22)
    }
}
