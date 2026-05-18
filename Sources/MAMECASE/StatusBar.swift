import SwiftUI

/// Bottom-of-window status bar.
///
/// Layout (matches macOS conventions):
///   leading — selection summary (system / single entry / multi-select)
///   trailing — async progress (Verify All, archive extract, brew install,
///              media downloads) when present, then the tile-size slider
struct StatusBar: View {
    let selectedEntries: [Entry]
    let totalCount: Int
    let systemName: String?
    let verifications: [Entry.ID: RomStatus]
    /// Free-form line surfaced from long-running tasks. When non-nil it
    /// appears between the selection summary and the slider with a
    /// spinner.
    let busyStatus: String?
    @Binding var gridItemSize: Double

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if let status = selectedStatus {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.tint)
                        .help("ROM status: \(status.label)")
                }
                Text(leadingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if let busyStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busyStatus)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(0.5)
            }

            Slider(value: $gridItemSize, in: 120...320)
                .controlSize(.small)
                .frame(width: 140)
                .help("Tile size")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectedStatus: RomStatus? {
        guard selectedEntries.count == 1 else { return nil }
        return verifications[selectedEntries[0].id]
    }

    private var leadingText: String {
        switch selectedEntries.count {
        case 0:
            if let systemName {
                return "\(systemName) — \(totalCount) entries"
            }
            return ""
        case 1:
            let e = selectedEntries[0]
            var parts: [String] = ["\(e.displayName) · \(e.shortName)"]
            if let y = e.year, !y.isEmpty { parts.append(y) }
            if let p = e.publisher, !p.isEmpty { parts.append(p) }
            if !e.owned { parts.append("missing") }
            return parts.joined(separator: " · ")
        default:
            return "\(selectedEntries.count) selected"
        }
    }
}
