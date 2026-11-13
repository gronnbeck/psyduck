import SwiftUI

/// The np.lol button: ink border, hard shadow, presses down into it.
struct InkButtonStyle: ButtonStyle {
    var fill: Color = Ink.accent
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = small ? 6 : 8
        let offset: CGFloat = configuration.isPressed ? 0 : (small ? 2 : 3)
        configuration.label
            .font(.sans(small ? 12 : 13, .semibold))
            .foregroundStyle(Ink.ink)
            .padding(.horizontal, small ? 9 : 14)
            .padding(.vertical, small ? 4 : 7)
            .inkBox(radius, fill: fill)
            .offset(x: (small ? 2 : 3) - offset, y: (small ? 2 : 3) - offset)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Ink.ink)
                    .offset(x: small ? 2 : 3, y: small ? 2 : 3)
            )
            .padding(.trailing, small ? 2 : 3)
            .padding(.bottom, small ? 2 : 3)
            .contentShape(Rectangle())
    }
}

/// A flat icon button for toolbars and rows.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sans(12, .medium))
            .foregroundStyle(Ink.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed ? Ink.paper3 : .clear))
            .contentShape(Rectangle())
    }
}

/// A full-ink hairline between panes.
struct InkRule: View {
    var vertical = true
    var body: some View {
        Rectangle().fill(Ink.ink)
            .frame(width: vertical ? Ink.border : nil, height: vertical ? nil : Ink.border)
    }
}

/// Centered message for a pane with nothing in it.
struct EmptyPane<Actions: View>: View {
    var title: String
    var message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.display(26)).foregroundStyle(Ink.ink)
            Text(message)
                .font(.sans(14))
                .foregroundStyle(Ink.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            actions
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension DiffFile.Status {
    var color: Color {
        switch self {
        case .added, .untracked: return Ink.leaf
        case .deleted: return Ink.berry
        case .modified, .other: return Ink.amber
        }
    }
}
