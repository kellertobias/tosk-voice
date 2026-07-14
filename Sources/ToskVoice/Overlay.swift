import AppKit
import SwiftUI

final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private let panel: NonActivatingPanel
    private weak var statusButton: NSStatusBarButton?

    init(model: AppModel, statusButton: NSStatusBarButton?) {
        self.statusButton = statusButton
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 188),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    func show(at placement: OverlayPlacement) {
        position(placement)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func position(_ placement: OverlayPlacement) {
        if placement == .menuBar, let button = statusButton, let buttonWindow = button.window {
            let frame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY - 8))
            clampToVisibleScreen()
            return
        }

        let screen = targetScreen()
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 22
        let x: CGFloat
        let y: CGFloat
        switch placement {
        case .topLeft: x = visible.minX + margin; y = visible.maxY - size.height - margin
        case .topCenter: x = visible.midX - size.width / 2; y = visible.maxY - size.height - margin
        case .topRight: x = visible.maxX - size.width - margin; y = visible.maxY - size.height - margin
        case .center: x = visible.midX - size.width / 2; y = visible.midY - size.height / 2
        case .bottomLeft: x = visible.minX + margin; y = visible.minY + margin
        case .bottomCenter: x = visible.midX - size.width / 2; y = visible.minY + margin
        case .bottomRight: x = visible.maxX - size.width - margin; y = visible.minY + margin
        case .menuBar: x = visible.midX - size.width / 2; y = visible.maxY - size.height - margin
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func targetScreen() -> NSScreen {
        if let app = NSWorkspace.shared.frontmostApplication,
           let window = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let bounds = window.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier })?[kCGWindowBounds as String] as? [String: CGFloat],
           let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] {
            let quartzPoint = CGPoint(x: x + width / 2, y: y + height / 2)
            if let screen = NSScreen.screens.first(where: { screen in
                let cocoaPoint = CGPoint(x: quartzPoint.x, y: NSScreen.screens[0].frame.maxY - quartzPoint.y)
                return screen.frame.contains(cocoaPoint)
            }) { return screen }
        }
        return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func clampToVisibleScreen() {
        let visible = targetScreen().visibleFrame
        var origin = panel.frame.origin
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
    }
}

private struct OverlayView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 10) {
                stateIndicator
                Text(model.state.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(model.profile.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.state.isActive {
                    Button {
                        Task { await model.cancel() }
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Discard dictation")
                        .help("Discard dictation")
                    Button {
                        Task { await model.stop() }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 20, height: 20)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .green)
                                .offset(x: 3, y: 3)
                        }
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .accessibilityLabel("Finish and insert dictation")
                    .help("Finish and insert dictation")
                }
            }

            WaveformView(levels: model.waveform, active: model.state == .listening, reduceMotion: reduceMotion)
                .frame(height: 44)

            LiveTranscriptView(
                finalizedText: model.finalizedText,
                volatileText: model.volatileText,
                statusDetail: model.statusDetail
            )
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .frame(height: 42)

            HStack {
                Label(model.profile.speechMode.label, systemImage: "character.bubble")
                Spacer()
                Label(model.profile.destination.label, systemImage: model.profile.destination == .focusedField ? "text.cursor" : "doc.text")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 520, height: 188)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 0.5))
    }

    private var stateIndicator: some View {
        Circle()
            .fill(model.state == .listening ? Color.red : model.state.isActive ? Color.orange : Color.green)
            .frame(width: 9, height: 9)
            .shadow(color: model.state == .listening ? .red.opacity(0.5) : .clear, radius: 4)
    }
}

private struct LiveTranscriptView: View {
    let finalizedText: String
    let volatileText: String
    let statusDetail: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0

    private var displayText: String {
        [finalizedText, volatileText]
            .filter { !$0.isEmpty }
            .joined(separator: finalizedText.isEmpty ? "" : " ")
    }

    var body: some View {
        GeometryReader { viewport in
            transcript
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: viewport.size.width, alignment: .leading)
                .background {
                    GeometryReader { content in
                        Color.clear.preference(
                            key: TranscriptHeightPreferenceKey.self,
                            value: content.size.height
                        )
                    }
                }
                .offset(y: min(0, viewport.size.height - contentHeight))
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.24),
                    value: contentHeight
                )
        }
        .clipped()
        .onPreferenceChange(TranscriptHeightPreferenceKey.self) { height in
            contentHeight = height
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayText.isEmpty ? statusDetail : displayText)
    }

    private var transcript: Text {
        if displayText.isEmpty {
            return Text(statusDetail).foregroundColor(.secondary.opacity(0.72))
        }

        let confirmed = Text(finalizedText).foregroundColor(.primary)
        let separator = Text(!finalizedText.isEmpty && !volatileText.isEmpty ? " " : "")
        let provisional = Text(volatileText).foregroundColor(.secondary)
        return Text("\(confirmed)\(separator)\(provisional)")
    }
}

private struct TranscriptHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WaveformView: View {
    let levels: [Float]
    let active: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let spacing = size.width / CGFloat(max(levels.count, 1))
                for (index, level) in levels.enumerated() {
                    let normalized = active ? CGFloat(max(0.07, level)) : 0.06
                    let height = max(3, normalized * size.height)
                    let rect = CGRect(
                        x: CGFloat(index) * spacing + spacing * 0.25,
                        y: (size.height - height) / 2,
                        width: max(1.5, spacing * 0.5),
                        height: height
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: spacing), with: .color(active ? .accentColor.opacity(0.88) : .secondary.opacity(0.35)))
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: levels)
        .accessibilityHidden(true)
    }
}
