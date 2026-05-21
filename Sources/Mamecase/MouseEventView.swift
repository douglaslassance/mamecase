import AppKit
import SwiftUI

/// `NSView`-backed click capture so single-clicks fire immediately and
/// right-clicks can synchronise selection before SwiftUI's context menu
/// appears.
///
/// `onClick` is called on every left-press with the click count and the
/// modifier flags captured at the moment of the press — capturing them
/// up front matters, since a SwiftUI closure reading `NSEvent.modifierFlags`
/// often sees the keys already released by the time it runs.
///
/// `onRightClick` (optional) is called *before* the right-click is
/// propagated up the responder chain so callers can adjust the selection
/// (e.g. select an unselected tile before SwiftUI's `.contextMenu` builds
/// its items).
struct MouseEventView: NSViewRepresentable {
    let onClick: (Int, NSEvent.ModifierFlags) -> Void
    var onRightClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> Backing {
        let v = Backing()
        v.onClick = onClick
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: Backing, context: Context) {
        nsView.onClick = onClick
        nsView.onRightClick = onRightClick
    }

    final class Backing: NSView {
        var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
        var onRightClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onClick?(event.clickCount, event.modifierFlags)
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
            super.rightMouseDown(with: event)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
