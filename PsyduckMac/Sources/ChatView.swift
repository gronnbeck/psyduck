import SwiftUI

/// One workspace's conversation with claude, and the box to talk in.
struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var running: Bool { store.isRunning(workspace.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            InkRule(vertical: false)
            transcript
            InkRule(vertical: false)
            composer
        }
        .background(Ink.paper)
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(workspace.name).font(.sans(16, .semibold))
            Text(workspace.branch).font(.mono(11)).foregroundStyle(Ink.ink3)
            Text("from \(workspace.baseRef) @ \(workspace.baseCommit.prefix(7))")
                .font(.mono(11)).foregroundStyle(Ink.ink4)
            Spacer()
            if running {
                ProgressView().controlSize(.small)
                Button("stop") { store.stop(workspace.id) }
                    .buttonStyle(InkButtonStyle(fill: Ink.paper, small: true))
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if workspace.items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("new workspace").microLabel()
                            Text("claude will run in")
                                .font(.sans(14)).foregroundStyle(Ink.ink3)
                            Text(workspace.path).font(.mono(12)).textSelection(.enabled)
                        }
                        .padding(.top, 8)
                    }
                    ForEach(workspace.items) { item in
                        ChatRow(item: item)
                    }
                    if let partial = store.streaming[workspace.id], !partial.isEmpty {
                        ChatRow(item: ChatItem(kind: .assistant, text: partial))
                    }
                    if running && (store.streaming[workspace.id] ?? "").isEmpty {
                        Text("thinking…").font(.mono(12)).foregroundStyle(Ink.ink3)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .onChange(of: workspace.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.streaming[workspace.id]) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(running ? "claude is working…" : "ask claude to do something in \(workspace.name)",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.sans(14))
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit(send)
                .padding(10)
                .inkBox(8, fill: .white.opacity(0.35))
            Button("send →", action: send)
                .buttonStyle(InkButtonStyle())
                .disabled(running || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
    }

    private func send() {
        guard !running else { return }
        store.send(draft, to: workspace.id)
        draft = ""
    }
}

private struct ChatRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(item.text)
                    .font(.sans(14))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .inkBox(10, fill: Ink.acid)
            }
        case .assistant:
            Text(markdown(item.text))
                .font(.sans(14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.text).font(.mono(11, .semibold))
                        .foregroundStyle(item.isError ? Ink.berry : Ink.ink2)
                    if let first = item.detail?.split(separator: "\n").first {
                        Text(String(first)).font(.mono(11)).foregroundStyle(Ink.ink3).lineLimit(1).truncationMode(.middle)
                    }
                }
                if item.isError, let detail = item.detail, let error = detail.split(separator: "\n", maxSplits: 1).dropFirst().first {
                    Text(String(error)).font(.mono(10)).foregroundStyle(Ink.berry).lineLimit(3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Ink.paper2))
        case .meta:
            Text(item.text).font(.mono(10)).foregroundStyle(Ink.ink4)
        case .error:
            Text(item.text)
                .font(.mono(12))
                .foregroundStyle(Ink.berry)
                .textSelection(.enabled)
                .padding(10)
                .inkBox(8, fill: Ink.berry.opacity(0.08), border: Ink.berry)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
