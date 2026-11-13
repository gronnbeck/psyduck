import AppKit
import SwiftUI

/// Tinker, psyduck's design system. Every value here is a Tinker token, from
/// the "Psyduck in Tinker" design canvas (`project/ds/tinker/tokens.json`).
/// Colours follow the system appearance: dark and light are both first-class.
enum Tk {
    // Surfaces
    static let bg000 = dynamic(dark: 0x0E0F13, light: 0xFAFAF7)   // canvas: chat, code, diffs
    static let bg100 = dynamic(dark: 0x15171C, light: 0xF3F3EE)   // chrome: sidebar, panels, status bar
    static let bg200 = dynamic(dark: 0x1C1F26, light: 0xFFFFFF)   // raised: cards, inputs, bubbles
    static let bg300 = dynamic(dark: 0x262A33, light: 0xE8E8E1)   // hover/selected rows, secondary buttons
    static let line = dynamic(dark: 0x2C303A, light: 0xDEDED6)    // hairlines, decorative only
    static let lineStrong = dynamic(dark: 0x6B7282, light: 0x7D8392) // control borders

    // Text
    static let ink = dynamic(dark: 0xECEEF3, light: 0x16181D)
    static let inkMuted = dynamic(dark: 0x9AA1B0, light: 0x565C68)
    static let inkFaint = dynamic(dark: 0x828999, light: 0x636878)

    // Brand and accents
    static let brand = Color(hex: 0xC6F432)                        // fizz lime
    static let onBrand = Color(hex: 0x14180A)
    static let brandText = dynamic(dark: 0xC6F432, light: 0x4D7A00)
    static let brandLedge = Color(hex: 0x6F8F12)                   // keycap ledge under brand
    static let pop = Color(hex: 0xFF6B4A)                          // coral: the agent avatar, one per view
    static let popText = dynamic(dark: 0xFF8A6E, light: 0xB8361A)

    // Status
    static let focus = dynamic(dark: 0x5EC8FF, light: 0x0B6FA8)
    static let success = dynamic(dark: 0x3DDC84, light: 0x157A3F)
    static let warning = dynamic(dark: 0xFFC53D, light: 0x8F5D00)
    static let danger = dynamic(dark: 0xFF5C6C, light: 0xC8243A)
    static let onDanger = dynamic(dark: 0x1A0508, light: 0xFFFFFF)
    static let info = dynamic(dark: 0x5EC8FF, light: 0x0B6FA8)

    // Syntax
    static let synFunction = dynamic(dark: 0x5EC8FF, light: 0x0B6FA8)

    /// The keycap ledge under secondary buttons and Kbd.
    static let keyLedge = dynamic(dark: 0x07080A, light: 0xC9C9C0)

    // Radii
    static let radiusSm: CGFloat = 4
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 12

    /// Height of every pane header, so they line up across the window.
    static let headerHeight: CGFloat = 56

    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

enum TypeWeight {
    case regular, medium, semibold, bold
}

/// Tinker's three families, all bundled: Inter for the interface, Bricolage
/// Grotesque for display moments, JetBrains Mono for code, branches and counts.
extension Font {
    static func sans(_ size: CGFloat, _ weight: TypeWeight = .regular) -> Font {
        switch weight {
        case .regular: return .custom("Inter-Regular", size: size)
        case .medium: return .custom("Inter-Medium", size: size)
        case .semibold: return .custom("Inter-SemiBold", size: size)
        case .bold: return .custom("Inter-Bold", size: size)
        }
    }

    static func mono(_ size: CGFloat, _ weight: TypeWeight = .regular) -> Font {
        switch weight {
        case .regular: return .custom("JetBrainsMono-Regular", size: size)
        case .medium: return .custom("JetBrainsMono-Medium", size: size)
        case .semibold: return .custom("JetBrainsMono-SemiBold", size: size)
        case .bold: return .custom("JetBrainsMono-Bold", size: size)
        }
    }

    /// Bricolage Grotesque: the wordmark, empty states, page titles.
    static func display(_ size: CGFloat) -> Font {
        .custom("BricolageGrotesque-Bold", size: size)
    }
}

extension View {
    /// Tinker's 11px uppercase section label ("CHANGES", repo names).
    func sectionLabel() -> some View {
        font(.sans(11, .semibold))
            .tracking(0.66)
            .textCase(.uppercase)
            .foregroundStyle(Tk.inkFaint)
    }

    /// A rounded surface with a 1px border.
    func tkCard(_ radius: CGFloat = Tk.radiusLg, fill: Color = Tk.bg200, border: Color = Tk.line) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: 1))
    }

    /// Inline code: mono, tinted chip.
    func codeChip() -> some View {
        font(.mono(12))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .tkCard(Tk.radiusSm)
    }
}
