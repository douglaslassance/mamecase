import AppKit
import SwiftUI

/// Transparent NSView placed as an **overlay** on top of the gallery's
/// `LazyVGrid`. Its `hitTest` returns `nil` for any point that falls
/// inside one of the known tile frames so AppKit routes those clicks
/// down to the tile's `MouseEventView`; clicks on empty gallery space
/// hit this view and become marquee/deselect.
///
/// `tileFrames` are expected in this view's own coordinate space — which
/// is the same as the gallery `.coordinateSpace(name: "gallery")` because
/// the overlay sits on the padded `LazyVGrid` whose origin is (0,0) in
/// the ScrollView's content coord space.
struct GalleryBackgroundView: NSViewRepresentable {
    let tileFrames: [CGRect]
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
        v.tileFrames = tileFrames
        v.onClick = onClick
        v.onDragChanged = onDragChanged
        v.onDragEnded = onDragEnded
    }

    final class Backing: NSView {
        var tileFrames: [CGRect] = []
        var onClick: (() -> Void)?
        var onDragChanged: ((CGPoint, CGPoint, NSEvent.ModifierFlags) -> Void)?
        var onDragEnded: (() -> Void)?

        private var origin: CGPoint?
        private var didDrag: Bool = false

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Pass clicks on tile rectangles through to the underlying tile's
        /// `MouseEventView`. Clicks elsewhere hit this view.
        override func hitTest(_ point: NSPoint) -> NSView? {
            for rect in tileFrames where rect.contains(point) {
                return nil
            }
            return super.hitTest(point)
        }

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
