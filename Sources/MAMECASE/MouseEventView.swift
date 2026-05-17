import AppKit
import SwiftUI

/// `NSView`-backed click capture so single-clicks fire immediately.
///
/// SwiftUI's `onTapGesture(count: 1)` is delayed by the system double-click
/// interval whenever a `count: 2` gesture is attached to the same view —
/// which makes selecting a single tile feel laggy. Reading `clickCount`
/// directly from `NSEvent.mouseDown` avoids that wait entirely.
///
/// `onClick` is called on every press with the live click count, so a
/// single click reports `1` immediately and a follow-up press reports `2`
/// before any timer fires.
struct MouseEventView: NSViewRepresentable {
    let onClick: (Int) -> Void

    func makeNSView(context: Context) -> Backing {
        let v = Backing()
        v.onClick = onClick
        return v
    }

    func updateNSView(_ nsView: Backing, context: Context) {
        nsView.onClick = onClick
    }

    final class Backing: NSView {
        var onClick: ((Int) -> Void)?

        override func mouseDown(with event: NSEvent) {
            onClick?(event.clickCount)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
