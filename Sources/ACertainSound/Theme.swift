import SwiftUI

/// Minimal, elegant broadcast-console palette: near-black green-tinted surfaces,
/// a restrained monochrome-green type scale, hairline separators, and a single
/// brighter green accent reserved for the live / now-playing state.
enum Theme {
    // Surfaces — a whisper of green keeps the whole console monochrome-green.
    static let background = Color(red: 0.043, green: 0.055, blue: 0.047)   // #0B0E0C
    static let surface    = Color(red: 0.075, green: 0.090, blue: 0.078)   // #131713
    static let surfaceHi  = Color(red: 0.110, green: 0.130, blue: 0.114)   // #1C211D

    // Text — green-tinted greys for a cohesive monochrome-green feel.
    static let textPrimary   = Color(red: 0.88, green: 0.93, blue: 0.88)
    static let textSecondary = Color(red: 0.56, green: 0.63, blue: 0.57)
    static let textTertiary  = Color(red: 0.38, green: 0.44, blue: 0.39)

    // Single accent — a clean signal green, used sparingly for "live".
    static let accent     = Color(red: 0.40, green: 0.80, blue: 0.52)       // #66CC85
    static let accentSoft = Color(red: 0.40, green: 0.80, blue: 0.52).opacity(0.14)

    // Hairlines — faintly green.
    static let hairline = Color(red: 0.55, green: 0.95, blue: 0.65).opacity(0.07)

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
