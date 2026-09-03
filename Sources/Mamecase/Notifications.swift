import AppKit
import Foundation

enum AppNotification {
    static let showAboutWindow = NSNotification.Name("ShowAboutWindow")
    /// Space or ⌘I: open the detail card on the selected entry, or close
    /// it if it's already up.
    static let toggleEntryDetails = NSNotification.Name("ToggleEntryDetails")
}

/// Space-bar capture, ahead of the responder chain.
///
/// The gallery can't do this with SwiftUI's `onKeyPress`: that only fires
/// on the focused view, and clicking a tile hands AppKit's first
/// responder to the enclosing scroll view, which swallows space as
/// page-down before SwiftUI ever sees it. A local event monitor runs
/// first, so space behaves the same whether the user reached a tile with
/// the mouse or the arrow keys.
///
/// The monitor only posts a notification — it deliberately holds no view
/// state, since a closure installed once would otherwise read a stale
/// snapshot of it.
enum SpaceKeyMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,   // space
                  !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option)
            else { return event }
            // Text input keeps its space: the search field's field
            // editor, the new-playlist sheet.
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            if NSApp.keyWindow?.isSheet == true { return event }
            NotificationCenter.default.post(name: AppNotification.toggleEntryDetails, object: nil)
            return nil
        }
    }
}
