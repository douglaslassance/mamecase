#if !APPSTORE_BUILD
import SwiftUI
import Sparkle

/// Process-wide Sparkle controller.
///
/// Shared rather than owned by `MamecaseApp` so the Settings toggle and
/// the menu command drive the same updater instance.
enum AppUpdater {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: {
            #if DEBUG
            return false  // Sparkle keys aren't in the dev Info.plist
            #else
            return true
            #endif
        }(),
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    static var updater: SPUUpdater { controller.updater }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var viewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

/// Settings toggle for Sparkle's background checks.
///
/// Sparkle asks once on first launch and records the answer in
/// `SUEnableAutomaticChecks`, then never asks again because
/// `SUHasLaunchedBefore` is set. Without this control a "Don't Check"
/// answer was permanent, since nothing else in the app writes that key.
struct AutomaticUpdatesToggle: View {
    let updater: SPUUpdater
    @State private var enabled: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _enabled = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Toggle("Check for updates automatically", isOn: $enabled)
            .onChange(of: enabled) { _, newValue in
                updater.automaticallyChecksForUpdates = newValue
            }
            // Sparkle can flip this itself (the first-launch prompt writes
            // it), so re-read on appear rather than trusting stale state.
            .onAppear { enabled = updater.automaticallyChecksForUpdates }
    }
}
#endif
