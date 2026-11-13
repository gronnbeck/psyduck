import SwiftUI

/// Tinker's button: primary (lime), secondary (keycap), ghost, danger. Primary
/// and secondary sit on a hard 2px ledge and drop onto it when pressed.
struct TkButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }

    var kind: Kind = .secondary
    var iconOnly = false
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let hasLedge = (kind == .primary || kind == .secondary) && isEnabled
        configuration.label
            .font(.sans(13, .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground(pressed))
            .padding(.horizontal, iconOnly ? 0 : 12)
            .frame(width: iconOnly ? height : nil, height: height)
            .background(
                RoundedRectangle(cornerRadius: Tk.radiusMd, style: .continuous)
                    .fill(background(pressed))
            )
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Tk.radiusMd, style: .continuous)
                        .strokeBorder(Tk.lineStrong, lineWidth: 1)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Tk.radiusMd, style: .continuous)
                    .fill(kind == .primary ? Tk.brandLedge : Tk.keyLedge)
                    .offset(y: hasLedge && !pressed ? 2 : 0)
                    .opacity(hasLedge ? 1 : 0)
            )
            .offset(y: hasLedge && pressed ? 2 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    private func foreground(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return Tk.onBrand
        case .secondary: return Tk.ink
        case .ghost: return pressed ? Tk.ink : Tk.inkMuted
        case .danger: return Tk.onDanger
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return Tk.brand
        case .secondary: return Tk.bg300
        case .ghost: return pressed ? Tk.bg300 : .clear
        case .danger: return Tk.danger
        }
    }
}

extension ButtonStyle where Self == TkButtonStyle {
    static var tkPrimary: TkButtonStyle { TkButtonStyle(kind: .primary) }
    static var tkSecondary: TkButtonStyle { TkButtonStyle(kind: .secondary) }
    static var tkGhost: TkButtonStyle { TkButtonStyle(kind: .ghost) }
    static func tkIcon(_ size: CGFloat = 32) -> TkButtonStyle { TkButtonStyle(kind: .ghost, iconOnly: true, height: size) }
}

/// A keycap hint: ⌘N, ⌘↵, Esc.
struct Kbd: View {
    let keys: String
    var onBrand = false

    var body: some View {
        Text(keys)
            .font(.mono(11, .medium))
            .foregroundStyle(onBrand ? Tk.onBrand : Tk.inkMuted)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: Tk.radiusSm)
                    .fill(onBrand ? Tk.onBrand.opacity(0.12) : Tk.bg300)
            )
            .overlay {
                if !onBrand {
                    RoundedRectangle(cornerRadius: Tk.radiusSm).strokeBorder(Tk.line, lineWidth: 1)
                }
            }
            .background {
                if !onBrand {
                    RoundedRectangle(cornerRadius: Tk.radiusSm).fill(Tk.keyLedge).offset(y: 2)
                }
            }
    }
}

/// A pill with a status dot: Ready, Running (pulsing), Failed.
struct StatusBadge<Label: View>: View {
    enum Status { case running, passed, failed, pending, idle }

    let status: Status
    @ViewBuilder var label: Label
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .background {
                    if status == .running {
                        Circle().stroke(Tk.info.opacity(pulse ? 0 : 0.55), lineWidth: pulse ? 8 : 0)
                    }
                }
            label
                .font(.sans(12, .medium))
                .foregroundStyle(Tk.ink)
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .frame(height: 22)
        .tkCard(999)
        .onAppear {
            guard status == .running else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private var dotColor: Color {
        switch status {
        case .running: return Tk.info
        case .passed: return Tk.success
        case .failed: return Tk.danger
        case .pending: return Tk.warning
        case .idle: return Tk.inkFaint
        }
    }
}

/// A 1px hairline between panes.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Tk.line)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// The pane-header row: 56px, with a hairline under it.
struct PaneHeader<Content: View>: View {
    var leading: CGFloat = 16
    var trailing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { content }
                .padding(.leading, leading)
                .padding(.trailing, trailing)
                .frame(height: Tk.headerHeight)
            Hairline()
        }
    }
}

/// Centered message for a pane with nothing in it.
struct EmptyPane<Actions: View>: View {
    var title: String
    var message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.display(22)).tracking(-0.2).foregroundStyle(Tk.ink)
            Text(message)
                .font(.sans(13))
                .lineSpacing(3)
                .foregroundStyle(Tk.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            actions.padding(.top, 4)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension DiffFile.Status {
    var color: Color {
        switch self {
        case .added, .untracked: return Tk.success
        case .deleted: return Tk.danger
        case .modified, .other: return Tk.warning
        }
    }

    var letter: String { self == .untracked ? "A" : rawValue }
}
