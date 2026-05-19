import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            MediaSettingsTab()
                .tabItem { Label("Media", systemImage: "photo.on.rectangle.angled") }
        }
        .frame(width: 600, height: 640)
    }
}

// MARK: - Appearance

/// Two sliders mirroring Peel's idiom: item spacing and tile corner
/// radius. Both write straight into `@AppStorage`, which the gallery
/// + tiles read directly.
private struct AppearanceSettingsTab: View {
    @AppStorage("itemSpacing") private var itemSpacing: Double = 16
    @AppStorage("tileCornerRadius") private var tileCornerRadius: Double = 10

    var body: some View {
        Form {
            Section("Item Spacing") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Compact")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Slider(value: $itemSpacing, in: 2...32, step: 2)
                        Text("Spacious")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    Text("\(Int(itemSpacing))px")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Corner Radius") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Sharp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Slider(value: $tileCornerRadius, in: 0...20, step: 1)
                        Text("Rounded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    Text("\(Int(tileCornerRadius))px")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Passive status pill rendered next to the MAME executable field.
/// Two flavours: a green "Up to date" with the detected version, or an
/// orange "Update available" hint that pairs with the active "Update
/// with Homebrew" button next to it.
private struct MameVersionBadge: View {
    let version: String?
    let updateAvailable: Bool

    var body: some View {
        let (tint, symbol, text) = appearance
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(tint.opacity(0.15))
        )
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 0.5)
        )
        .help(version ?? "MAME version unknown")
    }

    private var appearance: (Color, String, String) {
        let label = shortVersion ?? "Installed"
        if updateAvailable {
            return (.orange, "exclamationmark.circle.fill", "\(label) — update available")
        }
        return (.green, "checkmark.circle.fill", "\(label) — up to date")
    }

    /// Extract a tight version label from the banner — prefer `v0.260`
    /// if present, otherwise fall back to the whole first line.
    private var shortVersion: String? {
        guard let v = version else { return nil }
        if let range = v.range(of: #"v\d+\.\d+"#, options: .regularExpression) {
            return String(v[range])
        }
        return v
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: Library

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
                        if BrewInstaller.brewExecutable() != nil, library.mameMissing {
                            Button {
                                Task { await library.installMameViaBrew(settings: settings) }
                            } label: {
                                if library.installingMame {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Install with Homebrew")
                                }
                            }
                            .disabled(library.installingMame)
                        }
                        if !library.mameMissing, library.mameBrewManaged {
                            MameVersionBadge(version: library.mameVersion,
                                             updateAvailable: library.mameUpdateAvailable)
                            if library.mameUpdateAvailable {
                                Button {
                                    Task { await library.upgradeMameViaBrew(settings: settings) }
                                } label: {
                                    if library.upgradingMame {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("Update with Homebrew")
                                    }
                                }
                                .disabled(library.upgradingMame)
                            }
                        } else if !library.mameMissing, library.mameVersion != nil {
                            MameVersionBadge(version: library.mameVersion,
                                             updateAvailable: false)
                        }
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
                    HStack(spacing: 8) {
                        TextField("",
                                  text: $settings.romDownloadBaseURL,
                                  prompt: Text("https://example.org/path/"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open") {
                            let raw = settings.romDownloadBaseURL
                                .trimmingCharacters(in: .whitespaces)
                            if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
                        }
                        .disabled(settings.romDownloadBaseURL
                            .trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("ROM downloads")
            } footer: {
                Text("Mamecase appends `<shortname>.zip` to this URL when downloading a ROM. Leave blank to hide the Download ROM action.")
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
