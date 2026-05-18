import SwiftUI

/// Bottom-of-window status bar. Shows a short description of the current
/// selection on the left and the tile-size slider on the right.
struct StatusBar: View {
    let selectedEntries: [Entry]
    let totalCount: Int
    let systemName: String?
    let verifications: [Entry.ID: RomStatus]
    /// Override line shown in place of the selection summary. Used for
    /// progress text from long-running tasks (Verify All, archive extract).
    let busyStatus: String?
    @Binding var gridItemSize: Double

    private static let sliderWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 0) {
            // Invisible column matching the slider's width on the trailing
            // side so the centered info text stays centered within the bar.
            Color.clear
                .frame(width: Self.sliderWidth, height: 1)

            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let busyStatus {
                    ProgressView().controlSize(.small)
                    Text(busyStatus)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
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
            }
            Spacer(minLength: 0)

            Slider(value: $gridItemSize, in: 120...320)
                .controlSize(.small)
                .frame(width: Self.sliderWidth)
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
