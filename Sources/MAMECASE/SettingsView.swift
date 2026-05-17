import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            pathsTab
                .tabItem { Label("Paths", systemImage: "folder") }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }

    private var pathsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("MAME") {
                Form {
                    LabeledContent("mame.ini directory") {
                        HStack {
                            TextField("", text: $settings.mameHomePath, prompt: Text("~/.mame"))
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { pickDirectory($settings.mameHomePath) }
                        }
                    }
                    LabeledContent("MAME executable") {
                        HStack {
                            TextField("", text: $settings.mameExecutablePath, prompt: Text("mame"))
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { pickFile($settings.mameExecutablePath) }
                        }
                    }
                }
            }

            GroupBox("Additional ROM paths") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Merged with paths from mame.ini's `rompath`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RomPathsEditor(paths: $settings.additionalRomPaths)
                }
                .padding(6)
            }
        }
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
        VStack(spacing: 6) {
            List(selection: $selection) {
                ForEach(Array(paths.enumerated()), id: \.offset) { idx, path in
                    Text(path).tag(Optional(idx))
                }
            }
            .frame(minHeight: 140)
            .border(Color.secondary.opacity(0.2))

            HStack {
                Button {
                    addPath()
                } label: { Image(systemName: "plus") }
                Button {
                    removeSelected()
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Spacer()
            }
        }
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
