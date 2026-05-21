import AppKit
import SwiftUI

/// Off-disk image size cache. Loading an image's natural dimensions
/// requires reading at least the header bytes; doing that synchronously
/// on the main thread for every tile in a 30k-entry view would kill
/// scroll performance. The cache loads sizes lazily on a background
/// queue and notifies observers as results stream in.
///
/// Layouts call `size(for:)`. When the URL isn't cached yet, the cache
/// schedules a one-shot load and returns nil — the layout falls back to
/// a per-system default ratio until the real size lands, at which point
/// `generation` bumps and SwiftUI re-renders the gallery.
@MainActor
final class ImageSizeCache: ObservableObject {
    static let shared = ImageSizeCache()

    private var sizes: [URL: CGSize] = [:]
    private var pending: Set<URL> = []
    private var failed: Set<URL> = []
    /// True while a coalesced bump is queued — see `scheduleBump()`.
    private var bumpScheduled: Bool = false
    @Published private(set) var generation: Int = 0

    /// Returns a cached size if available. If the URL hasn't been
    /// inspected yet, schedules a load and returns nil.
    func size(for url: URL) -> CGSize? {
        if let s = sizes[url] { return s }
        if failed.contains(url) { return nil }
        if !pending.contains(url) {
            pending.insert(url)
            Task.detached(priority: .utility) { [weak self] in
                let size = Self.measure(url: url)
                await self?.complete(url: url, size: size)
            }
        }
        return nil
    }

    /// Distinguishes "we tried to measure and got nothing" from "we
    /// haven't tried yet". The gallery uses this to pick a square
    /// placeholder for broken / zero-byte images, instead of inheriting
    /// the per-system portrait fallback.
    func didFail(_ url: URL) -> Bool {
        failed.contains(url)
    }

    private func complete(url: URL, size: CGSize?) {
        pending.remove(url)
        if let size, size.width > 0, size.height > 0 {
            sizes[url] = size
        } else {
            failed.insert(url)
        }
        scheduleBump()
    }

    /// Coalesce `generation` bumps. The cache used to bump on every
    /// measurement completion, which created a feedback loop in
    /// galleries with many entries: each bump triggers a SwiftUI re-
    /// render of the gallery, the masonry's `buildLayout()` walks every
    /// entry and queries `size(for:)` for each, those queries schedule
    /// fresh measurements, those measurements complete and bump again.
    /// 100ms debounce caps re-render rate to ~10 Hz regardless of how
    /// many measurements are in flight.
    private func scheduleBump() {
        guard !bumpScheduled else { return }
        bumpScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.bumpScheduled = false
            self.generation &+= 1
        }
    }

    /// Reads only the image's header for the natural pixel dimensions
    /// rather than decoding the full bitmap — much cheaper for the
    /// hundreds of tiles a masonry view requests on first scroll.
    nonisolated private static func measure(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}
