import AppKit

/// Decoded-artwork cache.
///
/// `NSImage(contentsOf:)` re-opens and re-parses the file on every call,
/// and the tiles called it straight from `body` — so every re-render of
/// a visible tile hit the disk. During a live window resize SwiftUI
/// re-renders every visible tile on every frame, which turned a resize
/// into hundreds of synchronous main-thread image loads per second.
///
/// Tiles now read `cached(_:)` (a dictionary hit, no I/O) and fall back
/// to `image(for:)`, which decodes on a background queue and fills the
/// cache. Decoding goes through `CGImageSourceCreateThumbnailAtIndex`
/// so a 4000px flyer scan doesn't sit in memory at full resolution.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Longest edge we keep. The tile-size slider tops out at 320pt and a
    /// vertical-masonry column can stretch to roughly twice its target
    /// before the layout adds a column, so ~640pt at 2x is the widest a
    /// tile gets. Smaller images are left alone — `CGImageSource` never
    /// upscales.
    nonisolated private static let maxPixelSize: CGFloat = 1400

    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        // Several screenfuls of tiles, bounded by bytes so a run of large
        // flyer scans can't balloon the footprint. NSCache also evicts
        // under memory pressure on its own.
        cache.countLimit = 400
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    /// Already-decoded image for `url`, or nil. Never touches the disk —
    /// safe to call from `body`.
    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Cached image, decoding it off the main thread on a miss.
    func image(for url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        let box = await Task.detached(priority: .userInitiated) {
            ImageBox(image: Self.decode(url: url))
        }.value
        guard let image = box.image else { return nil }
        let cost = Int(image.size.width * image.size.height) * 4
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    /// Drop everything. Used when the media generation bumps, since the
    /// file behind a URL can be replaced in place by an archive
    /// re-extraction or an "Update Media" run.
    func removeAll() {
        cache.removeAllObjects()
    }

    /// `NSImage` isn't `Sendable`; the instance is freshly created on the
    /// detached task and handed over exactly once, so the transfer is
    /// safe even though the compiler can't see that.
    private struct ImageBox: @unchecked Sendable {
        let image: NSImage?
    }

    nonisolated private static func decode(url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
