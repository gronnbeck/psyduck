import SwiftUI

/// One workspace's session with Claude: header, transcript, composer.
struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var running: Bool { store.isRunning(workspace.id) }

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
        guard let last = workspace.items.last, last.kind == .tool else { return "Agent is thinking…" }
        if let path = last.filePath { return "Agent is poking at \((path as NSString).lastPathComponent)…" }
        if last.isShell, let command = last.detail?.split(separator: " ").first { return "Agent is running \(command)…" }
        return "Agent is working…"
    }

    // MARK: Transcript

    /// The transcript as turns: each of your messages, then everything
    /// Claude did in reply, grouped under one avatar.
    private var turns: [Turn] {
        var result: [Turn] = []
        for item in workspace.items {
            if item.kind == .user {
                result.append(Turn(user: item, reply: []))
            } else if result.isEmpty {
                result.append(Turn(user: nil, reply: [item]))
            } else {
                result[result.count - 1].reply.append(item)
            }
        }
        return result
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if workspace.items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("New workspace").font(.display(22))
                            Text("Claude works in its own copy of \(workspace.baseRef), on \(workspace.branch):")
                                .font(.sans(13)).foregroundStyle(Tk.inkMuted)
                            Text(workspace.path).font(.mono(12)).foregroundStyle(Tk.inkMuted).textSelection(.enabled)
                        }
                    }
                    let turns = self.turns
                    ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                        if let user = turn.user { UserBubble(text: user.text) }
                        let isLast = index == turns.count - 1
                        let partial = isLast ? (store.streaming[workspace.id] ?? "") : ""
                        if !turn.reply.isEmpty || (isLast && running) {
                            ClaudeTurn(items: turn.reply, partial: partial, running: isLast && running)
                        }
                    }
                    if let queued = store.queued[workspace.id] {
                        UserBubble(text: queued, queued: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .onChange(of: workspace.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.streaming[workspace.id]) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
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
                .onSubmit(send)
            HStack(spacing: 8) {
                if running, let started = store.turnStarted[workspace.id] {
                    TimelineView(.periodic(from: started, by: 0.1)) { context in
                        Text(String(format: "%.1fs", context.date.timeIntervalSince(started)))
                    }
                    .font(.mono(12))
                    .foregroundStyle(Tk.inkFaint)
                    if store.queued[workspace.id] != nil {
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

private struct Turn {
    var user: ChatItem?
    var reply: [ChatItem]
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

/// Everything Claude did in one turn, under the coral avatar.
private struct ClaudeTurn: View {
    let items: [ChatItem]
    let partial: String
    let running: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Tk.pop)
                .frame(width: 24, height: 24)
                .overlay(Image(systemName: "asterisk").font(.system(size: 11, weight: .bold)).foregroundStyle(Tk.onBrand))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Claude").font(.sans(12, .semibold)).foregroundStyle(Tk.inkMuted)
                ForEach(items) { item in
                    ItemView(item: item, active: running && item.id == items.last?.id)
                }
                if !partial.isEmpty {
                    Prose(text: partial)
                } else if running && (items.last?.kind != .tool) {
                    Text("Thinking…").font(.sans(13)).foregroundStyle(Tk.inkFaint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .background(Tk.bg000)
        .clipShape(RoundedRectangle(cornerRadius: Tk.radiusLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tk.radiusLg, style: .continuous).strokeBorder(Tk.line, lineWidth: 1))
    }
}
