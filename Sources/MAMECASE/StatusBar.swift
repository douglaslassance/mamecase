import SwiftUI

/// Bottom-of-window status bar. Shows a short description of the current
/// selection on the left and the tile-size slider on the right.
struct StatusBar: View {
    let selectedEntries: [Entry]
    let totalCount: Int
    let systemName: String?
    let verifications: [Entry.ID: RomStatus]
    @Binding var gridItemSize: Double

    var body: some View {
        HStack(spacing: 8) {
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
            Spacer(minLength: 0)
            Slider(value: $gridItemSize, in: 120...320)
                .controlSize(.small)
                .frame(width: 160)
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
