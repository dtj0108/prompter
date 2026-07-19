import AppKit
import SwiftUI

/// Ambitious design-system tokens and shared components, mirrored from the
/// "Ambitious sign-in page design" claude.ai/design project (tokens/colors.css).
/// Light values are the auth/marketing surface; dark values follow the
/// platform's dark-first identity. Brand constants are identical in both.
enum AmbitiousDesign {
    // MARK: Brand (identical in light & dark)

    static let brandPrimary = fixed(0x4A9EFF)
    static let brandPrimaryDark = fixed(0x0051D5)
    static let success = fixed(0x00C853)
    static let warning = fixed(0xFF9800)
    static let error = fixed(0xCC0000)
    static let streak = fixed(0xFF6B35)

    // MARK: Semantic (theme-aware)

    static let background = dynamic(light: 0xFFFFFF, dark: 0x000000)
    static let card = dynamic(light: 0xF5F6F8, dark: 0x1A1A1A)
    static let text = dynamic(light: 0x1C1E21, dark: 0xE0E0E0)
    static let textSecondary = dynamic(light: 0x65676B, dark: 0xB0B0B0)
    static let textTertiary = dynamic(light: 0x8A8D91, dark: 0x707070)
    static let border = dynamic(light: 0xE1E4E8, dark: 0x2A2A2A)
    static let borderStrong = dynamic(light: 0xC8CCD0, dark: 0x404040)
    static let dotInactive = dynamic(light: 0x000000, lightAlpha: 0.15, dark: 0xFFFFFF, darkAlpha: 0.2)
    /// The hero black button (true black on light; card-black on the pure-black dark theme).
    static let blackButton = dynamic(light: 0x000000, dark: 0x1A1A1A)

    private static func fixed(_ hex: UInt32) -> Color {
        Color(nsColor: NSColor(ambitiousHex: hex))
    }

    private static func dynamic(
        light: UInt32, lightAlpha: CGFloat = 1,
        dark: UInt32, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(ambitiousHex: dark, alpha: darkAlpha)
                : NSColor(ambitiousHex: light, alpha: lightAlpha)
        })
    }
}

private extension NSColor {
    convenience init(ambitiousHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension View {
    /// Web-style pointing-hand cursor for anything clickable (arrow when disabled).
    func clickCursor(_ enabled: Bool = true) -> some View {
        pointerStyle(enabled ? .link : .default)
    }
}

/// The italic-heavy lowercase wordmark with its brand underline bar.
struct AmbitiousWordmark: View {
    var text = "ambitious"
    var size: CGFloat = 32
    var barWidth: CGFloat = 44
    var barHeight: CGFloat = 4
    var spacing: CGFloat = 6
    var color: Color = AmbitiousDesign.text

    var body: some View {
        VStack(spacing: spacing) {
            Text(text)
                .font(.system(size: size, weight: .heavy).italic())
                .tracking(-0.02 * size)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(color)
            RoundedRectangle(cornerRadius: barHeight / 2)
                .fill(AmbitiousDesign.brandPrimary)
                .frame(width: barWidth, height: barHeight)
        }
    }
}

/// The brand-tinted circular icon badge (mic hero, setup-step icons).
/// `glow` is the static halo; `pulsing` breathes it (the v2 mic step).
struct AmbitiousIconCircle: View {
    var symbol: String
    var diameter: CGFloat = 96
    var symbolSize: CGFloat = 38
    var glow = false
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(AmbitiousDesign.brandPrimary.opacity(0.1))
            Circle().strokeBorder(AmbitiousDesign.brandPrimary.opacity(0.4), lineWidth: 1.5)
            Image(systemName: symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(AmbitiousDesign.brandPrimary)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: shadowColor, radius: shadowRadius)
        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)
        .onAppear { if pulsing { pulse = true } }
    }

    private var shadowColor: Color {
        if pulsing { return AmbitiousDesign.brandPrimary.opacity(pulse ? 0.32 : 0.18) }
        return glow ? AmbitiousDesign.brandPrimary.opacity(0.25) : .clear
    }

    private var shadowRadius: CGFloat {
        if pulsing { return pulse ? 28 : 16 }
        return 24
    }
}

/// Filled brand button ("Next", "Sign in with ambitious"). Full-width lg by
/// default; `compact` is the inline size used inside setup-step content.
struct AmbitiousPrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, compact: compact)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 14 : 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 18 : 16)
                .frame(minHeight: compact ? 36 : 48)
                .frame(maxWidth: compact ? nil : .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovered && isEnabled ? AmbitiousDesign.brandPrimaryDark : AmbitiousDesign.brandPrimary)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .onHover { hovered = $0 && isEnabled }
                .clickCursor(isEnabled)
        }
    }
}

/// The hero wordmark button ("Sign in with ambitious"): black, white text,
/// subtle inner edge — the brand's blue underline bar lives in the label.
struct AmbitiousBlackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AmbitiousDesign.blackButton)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(hovered && isEnabled ? 0.08 : 0))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                )
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .onHover { hovered = $0 && isEnabled }
                .clickCursor(isEnabled)
        }
    }
}

/// Outlined neutral button ("Create an Ambitious account").
struct AmbitiousSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AmbitiousDesign.text)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(hovered ? 0.05 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(AmbitiousDesign.borderStrong, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .onHover { hovered = $0 && isEnabled }
                .clickCursor(isEnabled)
        }
    }
}
