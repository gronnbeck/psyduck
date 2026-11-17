import PsyduckCore
import SwiftUI

/// One workspace's session with Claude: header, transcript, composer.
struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var session: Transcript { store.transcript(workspace.id) }
    private var items: [ChatItem] { session.items }
    private var running: Bool { session.running }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
        .background(Tk.bg000)
        .onAppear { focused = true }
    }

    // MARK: Header

    private var header: some View {
        PaneHeader(leading: 24, trailing: 16) {
            Text(workspace.name).font(.sans(15, .semibold)).lineLimit(1)
            Text(workspace.branch)
                .font(.mono(12, .medium))
                .foregroundStyle(Tk.inkMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .tkCard(Tk.radiusSm)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                Text("\(workspace.baseRef) @ \(workspace.baseCommit.prefix(7))")
            }
            .font(.mono(12, .medium))
            .foregroundStyle(Tk.inkFaint)
            .lineLimit(1)
            Spacer(minLength: 8)
            if running {
                StatusBadge(status: .running) { Text(activity) }
            } else {
                StatusBadge(status: .passed) { Text("Ready") }
            }
            Menu {
                WorkspaceMenuItems(workspace: workspace)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
            .accessibilityLabel("Session options")
        }
    }

    /// "Agent is poking at user.rb…" — from the last tool call of this turn.
    private var activity: String {
        guard let last = items.last, last.kind == .tool else { return "Agent is thinking…" }
        if let path = last.filePath { return "Agent is poking at \((path as NSString).lastPathComponent)…" }
        if last.isShell, let command = last.detail?.split(separator: " ").first { return "Agent is running \(command)…" }
        return "Agent is working…"
    }

    // MARK: Transcript

    /// The transcript as flat rows: each of your messages, then everything
    /// Claude did in reply under one avatar. Flat, so the stack can be lazy
    /// and a long session builds only the rows on screen.
    private var rows: [Row] {
        var rows: [Row] = []
        var inReply = false
        var turn = 0
        func openReply() {
            if !inReply { rows.append(.claude(turn)); inReply = true }
        }
        let items = self.items
        let lastID = running ? items.last?.id : nil
        for item in items {
            if item.kind == .user {
                rows.append(.user(item))
                inReply = false
                turn += 1
            } else {
                openReply()
                rows.append(.item(item, active: item.id == lastID))
            }
        }
        if running {
            let partial = session.streaming
            if !partial.isEmpty {
                openReply()
                rows.append(.partial(partial))
            } else if !inReply || items.last?.kind != .tool {
                openReply()
                rows.append(.thinking)
            }
        }
        if let queued = session.queued { rows.append(.queued(queued)) }
        return rows
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("New workspace").font(.display(22))
                            Text("Claude works in its own copy of \(workspace.baseRef), on \(workspace.branch):")
                                .font(.sans(13)).foregroundStyle(Tk.inkMuted)
                            Text(workspace.path).font(.mono(12)).foregroundStyle(Tk.inkMuted).textSelection(.enabled)
                        }
                        .padding(.bottom, 24)
                    }
                    let rows = self.rows
                    ForEach(rows) { row in
                        RowView(row: row, first: row.id == rows.first?.id).equatable()
                    }
                    Color.clear.frame(height: 1).padding(.top, 24).id("bottom")
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            // Pinned to the bottom, so a block above the fold changing height
            // doesn't shove what you're reading around.
            .defaultScrollAnchor(.bottom)
            .onChange(of: items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.streaming) { proxy.scrollTo("bottom", anchor: .bottom) }
            .task {
                // A lazy stack only guesses its height at first, and can open
                // scrolled past its rows. Go to the end once it has settled.
                for delay in [0, 60, 250] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $draft,
                      prompt: Text(running ? "Queue a follow-up for when Claude is done"
                                           : "Ask Claude to do something in \(workspace.name)")
                        .foregroundStyle(Tk.inkFaint),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.sans(13))
                .lineSpacing(3)
                .lineLimit(2...12)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    // Inserts at the cursor via the field editor, unlike appending to `draft`.
                    NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                    return .handled
                }
                .onSubmit(send)
            HStack(spacing: 8) {
                if running, let started = session.turnStarted {
                    TimelineView(.periodic(from: started, by: 0.1)) { context in
                        Text(String(format: "%.1fs", context.date.timeIntervalSince(started)))
                    }
                    .font(.mono(12))
                    .foregroundStyle(Tk.inkFaint)
                    if session.queued != nil {
                        Text("· follow-up queued").font(.sans(12)).foregroundStyle(Tk.inkFaint)
                    }
                } else {
                    HStack(spacing: 4) {
                        Text("Works on a copy of")
                        Text(workspace.baseRef).font(.mono(12)).foregroundStyle(Tk.inkMuted)
                    }
                    .font(.sans(12))
                    .foregroundStyle(Tk.inkFaint)
                }
                Spacer()
                if running {
                    Button {
                        store.stop(workspace.id)
                    } label: {
                        HStack(spacing: 6) { Text("Stop"); Kbd(keys: "Esc") }
                    }
                    .buttonStyle(.tkSecondary)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                Button(action: send) {
                    HStack(spacing: 6) { Text(running ? "Queue" : "Send"); Kbd(keys: "⌘↵", onBrand: true) }
                }
                .buttonStyle(.tkPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .tkCard(Tk.radiusLg, fill: Tk.bg200, border: Tk.lineStrong)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(text, to: workspace.id)
        draft = ""
    }
}

/// One row of the transcript.
private enum Row: Identifiable, Equatable {
    case user(ChatItem)
    /// The avatar and name that open Claude's reply in a turn.
    case claude(Int)
    /// `active` is the tool call Claude is in the middle of.
    case item(ChatItem, active: Bool)
    /// Text still streaming in.
    case partial(String)
    case thinking
    case queued(String)

    var id: String {
        switch self {
        case .user(let item), .item(let item, _): return item.id.uuidString
        case .claude(let turn): return "claude-\(turn)"
        case .partial: return "partial"
        case .thinking: return "thinking"
        case .queued: return "queued"
        }
    }
}

/// Equatable, so a row whose content didn't change is not rebuilt when the
/// store publishes — which it does for every bit of streamed text.
private struct RowView: View, Equatable {
    let row: Row
    let first: Bool

    /// Replies sit to the right of the avatar: its 24px and a 12px gap.
    private let inset: CGFloat = 36

    var body: some View {
        switch row {
        case .user(let item):
            UserBubble(text: item.text).padding(.top, first ? 0 : 24)
        case .queued(let text):
            UserBubble(text: text, queued: true).padding(.top, first ? 0 : 24)
        case .claude:
            Text("Claude").font(.sans(12, .semibold)).foregroundStyle(Tk.inkMuted)
                .padding(.leading, inset)
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(Tk.pop)
                        .frame(width: 24, height: 24)
                        .overlay(Image(systemName: "asterisk").font(.system(size: 11, weight: .bold)).foregroundStyle(Tk.onBrand))
                        .accessibilityHidden(true)
                }
                .padding(.top, first ? 0 : 24)
        case .item(let item, let active):
            ItemView(item: item, active: active).padding(.leading, inset).padding(.top, 10)
        case .partial(let text):
            Prose(text: text).padding(.leading, inset).padding(.top, 10)
        case .thinking:
            Text("Thinking…").font(.sans(13)).foregroundStyle(Tk.inkFaint).padding(.leading, inset).padding(.top, 10)
        }
    }
}

private struct UserBubble: View {
    let text: String
    var queued = false

    var body: some View {
        HStack {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.sans(13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                                       bottomTrailingRadius: 4, topTrailingRadius: 12)
                        .fill(Tk.bg200))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                                    bottomTrailingRadius: 4, topTrailingRadius: 12)
                        .strokeBorder(Tk.line, style: StrokeStyle(lineWidth: 1, dash: queued ? [4, 3] : [])))
                    .opacity(queued ? 0.7 : 1)
                if queued {
                    Text("queued: sends when Claude is done").font(.sans(12)).foregroundStyle(Tk.inkFaint)
                }
            }
        }
    }
}

private struct ItemView: View {
    let item: ChatItem
    /// The tool call Claude is in the middle of.
    let active: Bool

    var body: some View {
        switch item.kind {
        case .assistant:
            Prose(text: item.text)
        case .tool:
            if item.isShell, let output = item.output, !output.isEmpty {
                TerminalBlock(command: item.detail ?? "", output: output, failed: item.isError)
            } else {
                ToolRow(item: item, active: active)
            }
        case .meta:
            Text(item.text).font(.mono(12)).foregroundStyle(Tk.inkFaint)
        case .error:
            Text(item.text)
                .font(.mono(12))
                .foregroundStyle(Tk.danger)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tkCard(Tk.radiusMd, fill: Tk.danger.opacity(0.08), border: Tk.danger.opacity(0.5))
        case .user:
            EmptyView()
        }
    }
}

/// Claude's prose: markdown inline styles, `code` as chips is too heavy for
/// AttributedString, so code spans just take the mono face.
private struct Prose: View {
    let text: String

    var body: some View {
        Text(attributed)
            .font(.sans(13))
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        guard var result = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .mono(12)
            result[run.range].foregroundColor = Tk.ink
            result[run.range].backgroundColor = Tk.bg200
        }
        return result
    }
}

/// One tool call: "Edited app/models/user.rb", "Running bin/rails test…".
private struct ToolRow: View {
    let item: ChatItem
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if active {
                    Circle().fill(Tk.info).frame(width: 8, height: 8)
                } else {
                    Image(systemName: icon).font(.system(size: 11))
                        .foregroundStyle(item.isError ? Tk.danger : Tk.inkMuted)
                }
                (Text(verb + " ").foregroundColor(Tk.inkMuted) + Text(subject).foregroundColor(Tk.ink)
                    + Text(active ? "…" : "").foregroundColor(Tk.inkMuted))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if item.isError, let output = item.output, !output.isEmpty {
                Text(output).foregroundStyle(Tk.danger).lineLimit(4)
            }
        }
        .font(.mono(12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tkCard(Tk.radiusMd, fill: Tk.bg100)
    }

    private var subject: String { item.detail?.split(separator: "\n").first.map(String.init) ?? "" }

    private var verb: String {
        switch item.text {
        case "Edit", "MultiEdit", "NotebookEdit": return active ? "Editing" : "Edited"
        case "Write": return active ? "Writing" : "Wrote"
        case "Read": return active ? "Reading" : "Read"
        case "Bash": return active ? "Running" : "Ran"
        case "Grep", "Glob": return active ? "Searching" : "Searched"
        case "WebFetch": return active ? "Fetching" : "Fetched"
        case "WebSearch": return active ? "Searching the web for" : "Searched the web for"
        case "Task", "Agent": return active ? "Delegating" : "Delegated"
        case "TodoWrite": return "Updated the plan"
        default: return item.text
        }
    }

    private var icon: String {
        switch item.text {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Read": return "doc.text"
        case "Bash": return "chevron.right"
        case "Grep", "Glob", "WebSearch": return "magnifyingglass"
        case "WebFetch": return "globe"
        case "TodoWrite": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// A shell command and what it printed, as Tinker's terminal block.
private struct TerminalBlock: View {
    let command: String
    let output: String
    let failed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                Text(command).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if failed {
                    StatusBadge(status: .failed) { Text("failed") }
                }
            }
            .font(.mono(12, .medium))
            .foregroundStyle(Tk.inkMuted)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Tk.bg100)
            Hairline()
            ScrollView(.horizontal) {
                Text(output)
                    .font(.mono(13))
                    .lineSpacing(4)
                    .foregroundStyle(Tk.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A legacy (mouse) scroller takes ~14pt of height and comes and
            // goes between layout passes, which made the whole transcript
            // jitter. Trackpad and shift-scroll still scroll sideways.
            .scrollIndicators(.never)
        }
        .background(Tk.bg000)
        .clipShape(RoundedRectangle(cornerRadius: Tk.radiusLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tk.radiusLg, style: .continuous).strokeBorder(Tk.line, lineWidth: 1))
    }
}
