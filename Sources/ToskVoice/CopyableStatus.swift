import AppKit
import SwiftUI

/// Status/error text with a small copy button, so error messages can be
/// copied instead of retyped. The button briefly turns into a checkmark
/// after copying.
struct CopyableStatusText: View {
    let text: String
    var color: Color? = nil
    var font: Font = .caption

    @State private var justCopied = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(font)
                .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .textSelection(.enabled)
            if !text.isEmpty {
                Button(action: copy) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(justCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .help("Copy this message")
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            justCopied = false
        }
    }
}
