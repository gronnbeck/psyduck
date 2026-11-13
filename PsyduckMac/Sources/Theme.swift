import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// The np.lol palette, as the design system names it. Paper is never white
/// and borders are always full ink.
enum Ink {
    static let paper = Color(hex: 0xF6F1E7)
    static let paper2 = Color(hex: 0xEDE7D8)
    static let paper3 = Color(hex: 0xDCD3BD)
    static let ink = Color(hex: 0x14110D)
    static let ink2 = Color(hex: 0x3A352D)
    static let ink3 = Color(hex: 0x776E5E)
    static let ink4 = Color(hex: 0xA99F8B)
    static let tomato = Color(hex: 0xFF4E2E)
    static let tomatoDeep = Color(hex: 0xC9341B)
    static let acid = Color(hex: 0xDCFF3F)
    static let leaf = Color(hex: 0x2F8F5C)
    static let amber = Color(hex: 0xE6A300)
    static let berry = Color(hex: 0xB5274D)

    /// psyduck's per-app accent. The design system lets each app pick one.
    static let accent = tomato

    /// Every border in the app.
    static let border: CGFloat = 1.5
}

enum TypeWeight {
    case regular, medium, semibold, bold
}

/// Two faces and one mono, exactly as the design system allows, plus
/// Boldonse for the rare display moment. All bundled; Japanese falls to the
/// system's Hiragino Sans.
enum Fonts {
    static func sansName(_ weight: TypeWeight) -> String {
        switch weight {
        case .regular: return "BricolageGrotesque-Regular"
        case .medium: return "BricolageGrotesque-Medium"
        case .semibold: return "BricolageGrotesque-SemiBold"
        case .bold: return "BricolageGrotesque-Bold"
        }
    }

    static func monoName(_ weight: TypeWeight) -> String {
        switch weight {
        case .regular: return "JetBrainsMono-Regular"
        case .medium: return "JetBrainsMono-Medium"
        case .semibold: return "JetBrainsMono-SemiBold"
        case .bold: return "JetBrainsMono-Bold"
        }
    }

    static func jpName(_ weight: TypeWeight) -> String {
        switch weight {
        case .regular: return "HiraginoSans-W3"
        case .medium: return "HiraginoSans-W5"
        case .semibold, .bold: return "HiraginoSans-W6"
        }
    }
}

extension Font {
    static func sans(_ size: CGFloat, _ weight: TypeWeight = .regular) -> Font {
        .custom(Fonts.sansName(weight), size: size)
    }

    static func mono(_ size: CGFloat, _ weight: TypeWeight = .regular) -> Font {
        .custom(Fonts.monoName(weight), size: size)
    }

    static func jp(_ size: CGFloat, _ weight: TypeWeight = .regular) -> Font {
        .custom(Fonts.jpName(weight), size: size)
    }

    /// Boldonse — sparingly.
    static func display(_ size: CGFloat) -> Font {
        .custom("Boldonse-Regular", size: size)
    }
}

extension View {
    /// 1.5pt ink border on a rounded rectangle, with a fill behind it.
    func inkBox(_ radius: CGFloat, fill: Color = .clear, border: Color = Ink.ink) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: Ink.border))
    }

    /// The signature hard shadow: an ink copy of the shape, offset.
    func hardShadow(_ radius: CGFloat, offset: CGFloat = 4) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Ink.ink).offset(x: offset, y: offset))
    }

    /// The small uppercase label the design uses above groups.
    func microLabel() -> some View {
        font(.sans(11, .medium))
            .tracking(0.66)
            .textCase(.uppercase)
            .foregroundStyle(Ink.ink3)
    }
}
