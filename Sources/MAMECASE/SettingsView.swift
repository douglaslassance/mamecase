import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            MediaSettingsTab()
                .tabItem { Label("Media", systemImage: "photo.on.rectangle.angled") }
        }
        .frame(width: 600, height: 640)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("MAME") {
                LabeledContent("mame.ini directory") {
                    HStack(spacing: 8) {
                        TextField("", text: $settings.mameHomePath, prompt: Text("~/.mame"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { pickDirectory($settings.mameHomePath) }
                    }
                }
                LabeledContent("MAME executable") {
                    HStack(spacing: 8) {
                        TextField("", text: $settings.mameExecutablePath, prompt: Text("mame"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

            Section {
                LabeledContent("Base URL") {
                    TextField("",
                              text: $settings.romDownloadBaseURL,
                              prompt: Text(AppSettingsDefaults.romDownloadBaseURL))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("ROM downloads")
            } footer: {
                Text("Mamecase appends `<shortname>.zip` to this URL when downloading a ROM. Leave blank to use the archive.org default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

// MARK: - Media

private struct MediaSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @State private var cacheSize: Int64? = nil
    @State private var isClearing: Bool = false

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        Form {
            Section {
                Toggle("Download missing media online",
                       isOn: $settings.onlineMediaFetchEnabled)
            } header: {
                Text("Sources")
            } footer: {
                Text("When on, missing flyers and snaps are fetched from libretro-thumbnails (arcade) and OpenVGDB (software). Off uses only local files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cache") {
                LabeledContent("Location") {
                    Text("~/Library/Caches/Mamecase/media")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Size on disk") {
                    if let size = cacheSize {
                        Text(Self.byteFormatter.string(fromByteCount: size))
                            .monospacedDigit()
                    } else {
                        Text("Calculating…").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Reveal in Finder") {
                        let url = URL(fileURLWithPath: NSString(string: "~/Library/Caches/Mamecase/media")
                            .expandingTildeInPath)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Spacer()
                    Button(role: .destructive) {
                        clearCache()
                    } label: {
                        Text(isClearing ? "Clearing…" : "Clear Cache")
                    }
                    .disabled(isClearing)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: isClearing) {
            await refreshCacheSize()
        }
    }

    private func refreshCacheSize() async {
        let size = await Task.detached(priority: .utility) {
            MediaProvider.shared.currentCacheSize()
        }.value
        await MainActor.run { cacheSize = size }
    }

    private func clearCache() {
        isClearing = true
        Task {
            await MediaProvider.shared.clearCache()
            await MainActor.run {
                isClearing = false
            }
        }
    }
}

// MARK: - ROM paths editor

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
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                Divider().frame(height: 16)
                Button { removeSelected() } label: {
                    Image(systemName: "minus").frame(width: 22, height: 22)
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
