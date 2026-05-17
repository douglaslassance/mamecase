import SwiftUI
import AppKit

@main
struct MAMECASEApp: App {
    @StateObject private var library = Library()
    @StateObject private var settings = AppSettings()

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

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
