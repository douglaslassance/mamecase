import SwiftUI
import AppKit

@main
struct MAMECASEApp: App {
    @StateObject private var library = Library()
    @StateObject private var settings = AppSettings()
    @AppStorage("showStatusBar") private var showStatusBar: Bool = true
    @AppStorage("showInspector") private var showInspector: Bool = false

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
            CommandMenu("View") {
                Toggle("Inspector", isOn: $showInspector)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Toggle("Status Bar", isOn: $showStatusBar)
                    .keyboardShortcut("/", modifiers: [.command, .shift])
                Divider()
                Button {
                    Task { await library.indexArcade() }
                } label: {
                    Text(library.arcadeIndexing ? "Refreshing…" : "Refresh")
                }
                .keyboardShortcut("r")
                .disabled(library.arcadeIndexing || library.config == nil)
                Button {
                    Task { await library.verifyAll() }
                } label: {
                    Text(library.isVerifyingAll ? "Verifying…" : "Verify All ROMs")
                }
                .disabled(library.isVerifyingAll || library.config == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
