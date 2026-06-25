import SwiftUI

/// Minimal, elegant broadcast-console palette: warm near-black surfaces,
/// restrained off-white type, hairline separators, and a single amber accent
/// reserved for the live / now-playing state.
enum Theme {
    // Surfaces
    static let background = Color(red: 0.055, green: 0.055, blue: 0.063)   // #0E0E10
    static let surface    = Color(red: 0.094, green: 0.094, blue: 0.105)   // #18181B
    static let surfaceHi  = Color(red: 0.137, green: 0.137, blue: 0.149)   // #232326

    // Text
    static let textPrimary   = Color(white: 0.93)
    static let textSecondary = Color(white: 0.58)
    static let textTertiary  = Color(white: 0.40)

    // Single accent — warm amber, used sparingly for "live".
    static let accent     = Color(red: 0.88, green: 0.64, blue: 0.34)       // #E0A356
    static let accentSoft = Color(red: 0.88, green: 0.64, blue: 0.34).opacity(0.14)

    // Hairlines
    static let hairline = Color.white.opacity(0.07)

    // Fonts
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }
}

/// Small uppercase tracked caption used for section labels — quietly elegant.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label())
            .tracking(1.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

extension View {
    /// A subtle card surface with a hairline border.
    func cardSurface(_ color: Color = Theme.surface) -> some View {
        self
            .background(color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}
