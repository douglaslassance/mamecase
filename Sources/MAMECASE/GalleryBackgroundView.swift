import AppKit
import SwiftUI

/// NSView placed behind the gallery's `LazyVGrid` to handle empty-space
/// clicks (deselect) and drags (marquee selection). Tile clicks reach the
/// `MouseEventView` overlay on each tile and never bubble to this view,
/// so this NSView only fires for clicks/drags on truly empty space.
///
/// Coordinates are reported in this view's own local space — which lines
/// up with SwiftUI's `.named("gallery")` coordinate space because we
/// install this view as the `.background` of the padded `LazyVGrid`
/// inside the gallery ScrollView.
struct GalleryBackgroundView: NSViewRepresentable {
    let onClick: () -> Void
    let onDragChanged: (_ start: CGPoint, _ current: CGPoint, _ flags: NSEvent.ModifierFlags) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> Backing {
        let v = Backing()
        v.onClick = onClick
        v.onDragChanged = onDragChanged
        v.onDragEnded = onDragEnded
        return v
    }

    func updateNSView(_ nsView: Backing, context: Context) {
        nsView.onClick = onClick
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
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
