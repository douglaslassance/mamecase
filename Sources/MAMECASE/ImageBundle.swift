import SwiftUI

extension Image {
    /// Load a symbol asset shipped in our SPM resource bundle.
    /// SwiftUI treats `.symbolset` entries as first-class symbol images,
    /// so this scales with `.font()` / `.imageScale()` just like
    /// `Image(systemName:)`.
    init(moduleSymbol name: String) {
        self.init(name, bundle: .module)
    }
}
