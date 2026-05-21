import SwiftUI

extension Bundle {
    /// Resolves the SPM resource bundle in a way that works both for
    /// `swift run` (where `Bundle.module` finds it via `bundleURL`) and
    /// for the bundled `Mamecase.app` (where resources end up under
    /// `Contents/Resources/`). `Bundle.module` only looks at the executable's
    /// `bundleURL` — for a packaged macOS app that's the app root, not the
    /// Resources dir, so the symbol catalog isn't found and SwiftUI
    /// falls back to a blank glyph.
    static let appResources: Bundle = {
        let bundleName = "Mamecase_Mamecase.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources")
                .appendingPathComponent(bundleName),
        ]
        for url in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return .main
    }()
}

extension Image {
    /// Load a symbol asset shipped in our SPM resource bundle.
    /// SwiftUI treats `.symbolset` entries as first-class symbol images,
    /// so this scales with `.font()` / `.imageScale()` just like
    /// `Image(systemName:)`.
    init(moduleSymbol name: String) {
        self.init(name, bundle: .appResources)
    }
}
