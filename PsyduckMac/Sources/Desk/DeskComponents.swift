import SwiftUI

// MARK: Buttons

/// A pressable keycap. Primary sits on fizz lime; secondary is a neutral key.
/// Both carry the 2px ledge and drop onto it when pressed.
struct HardButtonStyle: ButtonStyle {
    enum Kind { case filled, outlined }

    var kind: Kind = .filled
    /// Overrides the lime, for a filled button that isn't the main action.
    var fill: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        HardButton(configuration: configuration, kind: kind, fill: fill)
    }

    private struct HardButton: View {
        let configuration: Configuration
        let kind: Kind
        let fill: Color?
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let pressed = configuration.isPressed && enabled
            let primary = kind == .filled
            configuration.label
                .font(.sans(13, .semibold))
                .foregroundStyle(primary ? Ink.onBrand : Ink.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(primary ? (fill ?? Ink.brand) : (hovering ? Ink.line : Ink.bg300)))
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.lineStrong, lineWidth: 1)
                    }
                }
                .brightness(primary && hovering ? 0.04 : 0)
                .offset(y: pressed ? 2 : 0)
                .keyLedge(8, color: primary ? Ink.brandLedge : Ink.keyLedge, depth: pressed || !enabled ? 0 : 2)
                .opacity(enabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.08), value: pressed)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }
    }
}

/// Flat and quiet: muted text that lights up on hover.
struct GhostButtonStyle: ButtonStyle {
    var size: CGFloat = 13
    var color = Ink.inkMuted

    func makeBody(configuration: Configuration) -> some View {
        GhostButton(configuration: configuration, size: size, color: color)
    }

    private struct GhostButton: View {
        let configuration: Configuration
        let size: CGFloat
        let color: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.sans(size, .semibold))
                .foregroundStyle(hovering ? Ink.ink : color)
                .padding(.horizontal, 12)
                .frame(minHeight: size < 13 ? 26 : 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering || configuration.isPressed ? Ink.bg300 : .clear))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.08), value: hovering)
                .contentShape(Rectangle())
        }
    }
}

/// The follow-up question chips.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration)
    }

    private struct Chip: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.sans(12, .medium))
                .foregroundStyle(hovering ? Ink.ink : Ink.inkMuted)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(hovering ? Ink.bg300 : Ink.bg200))
                .overlay(Capsule().strokeBorder(Ink.line, lineWidth: Ink.border))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.08), value: hovering)
        }
    }
}

// MARK: Small pieces

/// Tinker's StatusBadge: a pill on a raised surface with a coloured dot. The
/// label always names the state; the dot is the second cue. `fill` makes it
/// the solid "fizz" pill — one per view at most.
struct Badge: View {
    let text: String
    var dot: Color? = nil
    var fill: Color? = nil
    var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            if let dot, fill == nil {
                PulseDot(color: dot, pulsing: pulsing)
            }
            Text(text)
                .font(.sans(12, .medium))
                .foregroundStyle(fill == nil ? Ink.ink : Ink.onBrand)
                .lineLimit(1)
        }
        .padding(.leading, dot != nil && fill == nil ? 7 : 9)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(Capsule().fill(fill ?? Ink.bg200))
        .overlay { if fill == nil { Capsule().strokeBorder(Ink.line, lineWidth: Ink.border) } }
        .fixedSize()
    }
}

/// An 8px state dot; running things pulse.
struct PulseDot: View {
    let color: Color
    var pulsing = false
    var size: CGFloat = 8

    var body: some View {
        if pulsing {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                Circle().fill(color).frame(width: size, height: size)
                    .background(Circle().fill(color.opacity(0.55 * (1 - t))).frame(width: size + 8 * t, height: size + 8 * t))
            }
            .frame(width: size, height: size)
        } else {
            Circle().fill(color).frame(width: size, height: size)
        }
    }
}

/// Tinker's checkbox: a small `radius-sm` square, lime when on.
struct CheckMark: View {
    let on: Bool
    var size: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(on ? Ink.brand : Ink.bg200)
            .overlay {
                if !on { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Ink.lineStrong, lineWidth: 1) }
            }
            .overlay {
                if on { Image(systemName: "checkmark").font(.system(size: size * 0.6, weight: .heavy)).foregroundStyle(Ink.onBrand) }
            }
            .frame(width: size, height: size)
    }
}

/// A status dot: checks, connection.
struct Dot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// "reviewing." → "reviewing.." → "reviewing..." while something runs.
struct Dots: View {
    let text: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.3)
            Text(text + String(repeating: ".", count: tick % 3 + 1))
        }
    }
}

/// Text input on a raised surface; focus shows as the 2px ring.
struct InkField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Ink.inkFaint))
            .textFieldStyle(.plain)
            .font(mono ? .mono(13) : .sans(13))
            .foregroundStyle(Ink.ink)
            .autocorrectionDisabled(mono)
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .inkBox(8, fill: Ink.bg200, border: Ink.lineStrong)
            .focusRing(focused, radius: 8)
            .animation(.easeOut(duration: 0.08), value: focused)
    }
}

/// Text with its inline markdown shown: `code` in mono on a raised wash,
/// bold, italic, struck-through, and links you can click.
struct SegmentedText: View {
    let text: String
    var size: CGFloat = 14
    var weight: TypeWeight = .regular
    var color = Ink.ink

    var body: some View {
        Text(attributed)
            .lineSpacing(size * 0.4)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for span in DeskProse.spans(text) {
            var run = AttributedString(span.code ? "\u{2009}\(span.text)\u{2009}" : span.text)
            if span.code {
                run.font = .mono(size * 0.88)
                run.backgroundColor = Ink.bg300
            } else {
                let heavy = span.bold || weight != .regular
                // Inter is bundled upright only, so italics are the system's.
                run.font = span.italic ? .system(size: size, weight: heavy ? .semibold : .regular).italic()
                    : .sans(size, span.bold ? .semibold : weight)
            }
            if span.strike { run.strikethroughStyle = .single }
            if let link = span.link {
                run.link = link
                run.foregroundColor = Ink.info
            }
            result += run
        }
        return result
    }
}

/// Numbered diff lines on the canvas; highlighted ones get a lime wash and
/// the lime selection bar.
struct CodeBlock: View {
    let lines: [CodeLine]
    let highlight: [Int]
    /// The reviewed code itself gets lime; context gets a neutral wash.
    var main = true
    /// Highlights run the full width of the card, not just the text.
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let on = highlight.contains(line.no)
                    HStack(spacing: 0) {
                        Text(String(line.no))
                            .foregroundStyle(Ink.inkFaint)
                            .frame(width: 44, alignment: .trailing)
                        Text(line.mark)
                            .foregroundStyle(markColor(line.mark))
                            .frame(width: 24)
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(Ink.ink)
                            .fixedSize()
                            .padding(.trailing, 24)
                    }
                    .font(.mono(13))
                    .frame(height: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(on ? (main ? Ink.brand.opacity(0.16) : Ink.bg300) : .clear)
                    .overlay(alignment: .leading) {
                        if on { Rectangle().fill(main ? Ink.brand : Ink.lineStrong).frame(width: 3) }
                    }
                }
            }
            .padding(.vertical, main ? 8 : 6)
            .frame(minWidth: width, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in width = new }
        })
    }

    private func markColor(_ mark: String) -> Color {
        switch mark {
        case "+": return Ink.success
        case "-": return Ink.danger
        default: return Ink.inkFaint
        }
    }
}

/// A section heading: a Bricolage title, an optional mono count, an optional
/// note on the right.
struct SectionHeader: View {
    let title: String
    var count: Int?
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.display(20)).foregroundStyle(Ink.ink)
            if let count { Text(String(count)).font(.mono(12, .medium)).foregroundStyle(Ink.inkMuted) }
            Spacer(minLength: 0)
            if let note { Text(note).font(.sans(12)).foregroundStyle(Ink.inkMuted) }
        }
    }
}

/// The raised card most content sits in.
struct Card<Content: View>: View {
    var padding = EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkBox(12, fill: Ink.bg200)
    }
}

/// A multi-line field that grows with its text, styled like `InkField`.
struct InkEditor: View {
    @Binding var text: String
    var placeholder = ""
    var mono = false
    var minHeight: CGFloat = 60
    @FocusState private var focused: Bool

    var body: some View {
        let font: Font = mono ? .mono(12) : .sans(13)
        ZStack(alignment: .topLeading) {
            // The hidden copy sizes the box; the editor fills it.
            Text(text.isEmpty ? " " : text + " ")
                .font(font).lineSpacing(4)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .opacity(0)
            if text.isEmpty {
                Text(placeholder).font(font).foregroundStyle(Ink.inkFaint).padding(.horizontal, 5)
            }
            TextEditor(text: $text)
                .font(font).lineSpacing(4)
                .foregroundStyle(Ink.ink)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .focused($focused)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .inkBox(8, fill: Ink.bg200, border: Ink.lineStrong)
        .focusRing(focused, radius: 8)
        .animation(.easeOut(duration: 0.08), value: focused)
    }
}
