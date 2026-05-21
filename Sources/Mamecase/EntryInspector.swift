import SwiftUI
import AppKit

/// Right-side inspector showing details + HISTORY text for the currently
/// single-selected entry. Shows a placeholder when nothing or many things
/// are selected.
struct EntryInspector: View {
    @EnvironmentObject var library: Library
    let entry: Entry?

    @State private var history: String?
    @State private var loading: Bool = false

    var body: some View {
        Group {
            if let entry {
                content(for: entry)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: entry?.id) {
            await loadHistory()
        }
    }

    private func loadHistory() async {
        guard let entry else {
            history = nil
            return
        }
        loading = true
        history = await library.historyText(for: entry)
        loading = false
    }

    @ViewBuilder
    private func content(for entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(for: entry)
            Divider()
            ScrollView {
                Group {
                    if loading {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Loading history…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if let history, !history.isEmpty {
                        Text(history)
                            .font(.system(.body, design: .default))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        Text("No history entry found for \(entry.shortName).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func header(for entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.displayName)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(entry.shortName).monospaced()
                if let year = entry.year, !year.isEmpty {
                    Text("·"); Text(year)
                }
                if let pub = entry.publisher, !pub.isEmpty {
                    Text("·"); Text(pub).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !entry.owned {
                Text("ROM missing")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Select an entry to see details.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
