import SwiftUI

/// psyduck is two apps in one window. The rail on the left edge picks which.
enum AppMode: String, CaseIterable, Identifiable {
    /// Workspaces: claude in git worktrees.
    case code
    /// Pull requests and reviews. This was the tsukue app.
    case desk

    static let defaultsKey = "mode"

    var id: String { rawValue }
    var label: String { rawValue }

    var icon: String {
        switch self {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .desk: return "tray.full"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .code: return "1"
        case .desk: return "2"
        }
    }

    var help: String {
        switch self {
        case .code: return "Code: workspaces and chats (⌘1)"
        case .desk: return "Desk: pull requests and reviews (⌘2)"
        }
    }
}

/// The window: the mode rail, then the app that is picked.
struct RootView: View {
    @AppStorage(AppMode.defaultsKey) private var mode: AppMode = .code
    @EnvironmentObject private var deskSettings: DeskSettings
    @EnvironmentObject private var prs: PRStore
    @EnvironmentObject private var reviews: ReviewStore
    /// Desk goes to GitHub, and reviews new requests with claude, only once
    /// it has been opened. Someone who only uses code never pays for it.
    @State private var deskStarted = false

    var body: some View {
        RootLayout(mode: $mode) {
            switch mode {
            case .code:
                ShellView()
            case .desk:
                DeskView()
                    // ⌘R syncs the pull requests.
                    .background {
                        Button("Refresh") { Task { await prs.refresh() } }
                            .keyboardShortcut("r", modifiers: .command)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
            }
        }
        .task(id: mode) { await startDeskIfNeeded() }
    }

    private func startDeskIfNeeded() async {
        guard mode == .desk, !deskStarted,
              // Tests host the app; they shouldn't go to GitHub.
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        deskStarted = true
        await deskSettings.detectMissing()
        reviews.follow(prs)
        prs.start()
    }
}

/// The rail, a hairline, then whichever app is showing.
struct RootLayout<Content: View>: View {
    @Binding var mode: AppMode
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            ModeRail(mode: $mode)
            Hairline(vertical: true)
            content
        }
        .background(Tk.bg100)
        .ignoresSafeArea()
    }
}

/// The strip on the window's left edge, under the traffic lights: one icon
/// per app.
struct ModeRail: View {
    @Binding var mode: AppMode

    static let width: CGFloat = 56

    var body: some View {
        VStack(spacing: 6) {
            // The window's traffic lights sit here.
            Color.clear.frame(height: 40)
            ForEach(AppMode.allCases) { item in
                ModeButton(item: item, active: mode == item) { mode = item }
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Tk.bg100)
    }
}

private struct ModeButton: View {
    let item: AppMode
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 20)
                Text(item.label).font(.mono(10, .medium))
            }
            .foregroundStyle(active || hovering ? Tk.ink : Tk.inkMuted)
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: Tk.radiusMd, style: .continuous)
                .fill(active ? Tk.bg300 : hovering ? Tk.bg200 : .clear))
            // Tinker's selected row: the lime bar on the left edge.
            .overlay(alignment: .leading) {
                if active { Capsule().fill(Tk.brand).frame(width: 3).padding(.vertical, 12).offset(x: -5) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.help)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
