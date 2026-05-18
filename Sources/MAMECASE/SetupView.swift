import SwiftUI

/// First-launch / broken-config landing page. Tells the user MAME wasn't
/// found and offers the two reasonable paths forward: open Settings to
/// browse for an existing install, or kick off a Homebrew install.
struct SetupView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Set up MAME")
                .font(.title)
            Text("Mamecase needs the MAME emulator binary to launch games and index the arcade catalogue.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                if BrewInstaller.brewExecutable() != nil {
                    Button {
                        Task { await library.installMameViaBrew(settings: settings) }
                    } label: {
                        if library.installingMame {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Install with Homebrew", systemImage: "shippingbox")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.installingMame)
                }
                Button {
                    openSettings()
                } label: {
                    Label("Open Settings…", systemImage: "gearshape")
                }
            }
            if let status = library.arcadeStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
