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
    // Held here so the controller is created at app construction, as
    // before. `AppUpdater` owns it so Settings can reach it too.
    private let updaterController = AppUpdater.controller
    #endif

    init() {
        // Without a proper .app bundle, an SPM executable defaults to a
        // background activation policy and never gets a visible window or
        // dock icon. Promote it to a regular GUI app on launch.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Mamecase") {
            AboutCommandHandler {
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
        }
        .windowStyle(.titleBar)
        .commands {
            // Mamecase is single-window; drop the default "New Window" item.
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About Mamecase") {
                    NotificationCenter.default.post(name: AppNotification.showAboutWindow, object: nil)
                }
                #if !APPSTORE_BUILD && !DEBUG
                CheckForUpdatesView(
                    viewModel: CheckForUpdatesViewModel(updater: updaterController.updater),
                    updater: updaterController.updater
                )
                #endif
            }
            CommandMenu("View") {
                // Posts rather than binding to state: the selection this
                // acts on lives in ContentView, and a menu closure here
                // can't see it.
                Button("Show Details") {
                    NotificationCenter.default.post(name: AppNotification.toggleEntryDetails,
                                                    object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])
                Divider()
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

        WindowGroup("About Mamecase", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct AboutCommandHandler<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .onReceive(NotificationCenter.default.publisher(for: AppNotification.showAboutWindow)) { _ in
                openWindow(id: "about")
            }
    }
}
