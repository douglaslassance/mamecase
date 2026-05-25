import SwiftUI
import AppKit
#if !APPSTORE_BUILD
import Sparkle
#endif

@main
struct MamecaseApp: App {
    @StateObject private var library = Library()
    @StateObject private var settings = AppSettings()
    @AppStorage("showStatusBar") private var showStatusBar: Bool = true
    @AppStorage("showInspector") private var showInspector: Bool = false
    #if !APPSTORE_BUILD
    private let updaterController = SPUStandardUpdaterController(
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
    #endif

    init() {
        // Without a proper .app bundle, an SPM executable defaults to a
        // background activation policy and never gets a visible window or
        // dock icon. Promote it to a regular GUI app on launch.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Mamecase") {
            ContentView()
                .environmentObject(library)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    library.observe(settings: settings)
                    await library.load(settings: settings)
                }
        }
        .windowStyle(.titleBar)
        .commands {
            // Mamecase is single-window; drop the default "New Window" item.
            CommandGroup(replacing: .newItem) { }
            #if !APPSTORE_BUILD && !DEBUG
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(
                    viewModel: CheckForUpdatesViewModel(updater: updaterController.updater),
                    updater: updaterController.updater
                )
            }
            #endif
            CommandMenu("View") {
                Toggle("Inspector", isOn: $showInspector)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Toggle("Status Bar", isOn: $showStatusBar)
                    .keyboardShortcut("/", modifiers: [.command, .shift])
                Divider()
                Button {
                    Task { await library.verifyAll() }
                } label: {
                    Text(library.isVerifyingAll ? "Verifying…" : "Verify All ROMs")
                }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(library.isVerifyingAll || library.config == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(library)
        }
    }
}
