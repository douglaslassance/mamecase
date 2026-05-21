import AppKit
import SwiftUI

/// Background NSView for the gallery. Sits **behind** the `LazyVGrid` so
/// AppKit hit-testing routes clicks naturally: empty grid space falls
/// through here, tile clicks hit each tile's own `MouseEventView`.
///
/// - `onClick` fires on mouse-up after no significant drag (= bare click).
/// - `onDragChanged` fires once the drag passes a small threshold and on
///   every subsequent move with the start + current location in this
///   view's local coordinate space.
/// - `onDragEnded` fires when the drag terminates after having moved.
struct GalleryBackgroundView: NSViewRepresentable {
    let onClick: () -> Void
    let onDragChanged: (_ start: CGPoint, _ current: CGPoint, _ flags: NSEvent.ModifierFlags) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> Backing {
        let v = Backing()
        apply(to: v)
        return v
    }

    func updateNSView(_ nsView: Backing, context: Context) {
        apply(to: nsView)
    }

    private func apply(to v: Backing) {
        v.onClick = onClick
        v.onDragChanged = onDragChanged
        v.onDragEnded = onDragEnded
    }

    final class Backing: NSView {
        var onClick: (() -> Void)?
        var onDragChanged: ((CGPoint, CGPoint, NSEvent.ModifierFlags) -> Void)?
        var onDragEnded: (() -> Void)?

        private var origin: CGPoint?
        private var didDrag: Bool = false

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            origin = convert(event.locationInWindow, from: nil)
            didDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = origin else { return }
            let current = convert(event.locationInWindow, from: nil)
            if !didDrag {
                let dx = current.x - start.x
                let dy = current.y - start.y
                if (dx * dx + dy * dy) >= 16 { didDrag = true }
            }
            if didDrag {
                onDragChanged?(start, current, event.modifierFlags)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if didDrag {
                onDragEnded?()
            } else {
                onClick?()
            }
            origin = nil
            didDrag = false
        }
    }
}
