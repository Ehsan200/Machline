import AppKit
import SwiftUI

/// Fonts, with a Persian fallback.
///
/// macOS already substitutes a font when the interface face has no glyph for a character, but it
/// picks the system Arabic face — which sets Persian text at a different weight and rhythm to the
/// Latin around it, and looks wrong beside it. Naming Vazirmatn in the cascade list makes the
/// substitution deliberate instead.
///
/// The cascade only applies to characters the primary face cannot draw, so Latin text is untouched.
enum Fonts {

    /// Installed on this machine rather than bundled. Nothing breaks without it: the cascade entry
    /// is simply ignored and macOS falls back as it did before.
    static let persianFamily = "Vazirmatn"

    /// Persian and Arabic digits and letters, plus the Arabic Presentation Forms.
    private static let persianRanges: [ClosedRange<UInt32>] = [
        0x0600...0x06FF,  // Arabic
        0x0750...0x077F,  // Arabic Supplement
        0x08A0...0x08FF,  // Arabic Extended-A
        0xFB50...0xFDFF,  // Arabic Presentation Forms-A
        0xFE70...0xFEFF   // Arabic Presentation Forms-B
    ]

    static func containsPersian(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            persianRanges.contains { $0.contains(scalar.value) }
        }
    }

    /// A UI font that falls back to Vazirmatn for Persian.
    static func ui(size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(cascading(NSFont.systemFont(ofSize: size, weight: weight)))
    }

    /// A monospace font with the same fallback.
    ///
    /// Persian inside a code block still wants a readable face; the monospace primary keeps its
    /// grid for the code around it.
    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(cascading(NSFont.monospacedSystemFont(ofSize: size, weight: weight)))
    }

    /// The AppKit font, for the places that are not SwiftUI — the composer is an `NSTextView`.
    static func nsUI(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        cascading(NSFont.systemFont(ofSize: size, weight: weight))
    }

    /// The AppKit monospace font, for the terminal view.
    static func nsMono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        cascading(NSFont.monospacedSystemFont(ofSize: size, weight: weight))
    }

    private static func cascading(_ base: NSFont) -> NSFont {
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: [NSFontDescriptor(fontAttributes: [.family: persianFamily])]
        ])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }
}
