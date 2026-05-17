import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("MAME") {
                LabeledContent("mame.ini directory") {
                    HStack(spacing: 8) {
                        TextField("", text: $settings.mameHomePath, prompt: Text("~/.mame"))
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { pickDirectory($settings.mameHomePath) }
                    }
                }
                LabeledContent("MAME executable") {
                    HStack(spacing: 8) {
                        TextField("", text: $settings.mameExecutablePath, prompt: Text("mame"))
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { pickFile($settings.mameExecutablePath) }
                    }
                }
            }

            Section {
                RomPathsEditor(paths: $settings.additionalRomPaths)
            } header: {
                Text("Additional ROM paths")
            } footer: {
                Text("Merged with paths from mame.ini's `rompath`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
    }

    private func pickDirectory(_ binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func pickFile(_ binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }
}

private struct RomPathsEditor: View {
    @Binding var paths: [String]
    @State private var selection: Int?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(paths.enumerated()), id: \.offset) { idx, path in
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .tag(Optional(idx))
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 160)

            HStack(spacing: 0) {
                Button { addPath() } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                Divider().frame(height: 16)
                Button { removeSelected() } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator),
                     alignment: .top)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    private func addPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !paths.contains(url.path) {
                paths.append(url.path)
            }
        }
    }

    private func removeSelected() {
        guard let idx = selection, paths.indices.contains(idx) else { return }
        paths.remove(at: idx)
        selection = nil
    }
}
