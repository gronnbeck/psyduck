import SwiftUI

extension Color {
    /// One colour per appearance; SwiftUI resolves it for whatever the
    /// window is showing.
    init(dark: UInt32, light: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The Tinker design system's tokens, by their names in `tokens.json`. Dark
/// is the primary theme and light a full equal; the app follows the system.
/// Surfaces climb in lightness so attention falls back to the content.
enum Ink {
    /// Canvas: the page ground, code and diffs.
    static let bg000 = Color(dark: 0x0E0F13, light: 0xFAFAF7)
    /// Chrome: the sidebar and bars around the content.
    static let bg100 = Color(dark: 0x15171C, light: 0xF3F3EE)
    /// Raised: cards, popovers, inputs.
    static let bg200 = Color(dark: 0x1C1F26, light: 0xFFFFFF)
    /// Hover and selected rows, secondary button faces, keycaps.
    static let bg300 = Color(dark: 0x262A33, light: 0xE8E8E1)
    /// Hairline dividers. Decorative only.
    static let line = Color(dark: 0x2C303A, light: 0xDEDED6)
    /// Control borders: inputs, secondary buttons.
    static let lineStrong = Color(dark: 0x6B7282, light: 0x7D8392)

    static let ink = Color(dark: 0xECEEF3, light: 0x16181D)
    static let inkMuted = Color(dark: 0x9AA1B0, light: 0x565C68)
    static let inkFaint = Color(dark: 0x828999, light: 0x636878)

    /// Fizz lime: primary buttons, active indicators, selection. Text on it
    /// is always `onBrand`; lime text is `brandText`.
    static let brand = Color(hex: 0xC6F432)
    static let onBrand = Color(hex: 0x14180A)
    static let brandText = Color(dark: 0xC6F432, light: 0x4D7A00)
    static let brandLedge = Color(hex: 0x6F8F12)
    /// Coral, the one playful accent per view.
    static let pop = Color(hex: 0xFF6B4A)
    static let popText = Color(dark: 0xFF8A6E, light: 0xB8361A)
    static let sky = Color(hex: 0x5EC8FF)
    static let sun = Color(hex: 0xFFD23F)
    static let focus = Color(dark: 0x5EC8FF, light: 0x0B6FA8)

    // Signals, for state only — always with a word or an icon beside them.
    static let success = Color(dark: 0x3DDC84, light: 0x157A3F)
    static let warning = Color(dark: 0xFFC53D, light: 0x8F5D00)
    static let danger = Color(dark: 0xFF5C6C, light: 0xC8243A)
    static let onDanger = Color(dark: 0x1A0508, light: 0xFFFFFF)
    static let info = Color(dark: 0x5EC8FF, light: 0x0B6FA8)

    /// The keycap ledge under pressable things.
    static let keyLedge = Color(dark: 0x07080A, light: 0xC9C9C0)

    /// Every border in the app: a 1px hairline.
    static let border: CGFloat = 1
}

/// Three families, each with one job: Bricolage Grotesque for the playful
/// voice (titles, empty states), Inter for the interface, JetBrains Mono for
/// code, numbers and branch names. All bundled; Japanese falls to the
/// system's Hiragino Sans.
extension Font {
    /// Japanese, in the system's Hiragino Sans. The other families are in
    /// psyduck's `Theme.swift`.
    static func jp(_ size: CGFloat, _ weight: TypeWeight = .regular) -> Font {
        switch weight {
        case .regular: return .custom("HiraginoSans-W3", size: size)
        case .medium: return .custom("HiraginoSans-W5", size: size)
        case .semibold, .bold: return .custom("HiraginoSans-W6", size: size)
        }
    }
}

extension View {
    /// A rounded surface with a 1px border. Borders do most of the work in
    /// Tinker; shadows are for pressable and floating things only.
    func inkBox(_ radius: CGFloat, fill: Color = .clear, border: Color = Ink.line) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: Ink.border))
    }

    /// The keycap ledge: a hard 2px edge under something you can press.
    func keyLedge(_ radius: CGFloat, color: Color = Ink.keyLedge, depth: CGFloat = 2) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(color).offset(y: depth))
    }

    /// Tinker's `label` style: small uppercase section labels. Never for
    /// sentences.
    func microLabel() -> some View {
        font(.sans(11, .semibold))
            .tracking(0.66)
            .textCase(.uppercase)
            .foregroundStyle(Ink.inkFaint)
    }

    /// The 2px focus ring, offset 2px, outside an input.
    func focusRing(_ on: Bool, radius: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
            .strokeBorder(Ink.focus, lineWidth: 2).padding(-3).opacity(on ? 1 : 0))
    }
}
