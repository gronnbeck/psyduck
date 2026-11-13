import SwiftUI

/// The right-hand panel: every file the workspace has changed since it was
/// cut from its base. Clicking one opens its diff in the center pane.
struct ChangesPanel: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace

    private var files: [DiffFile] { store.changes[workspace.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrimaryActionBar(workspace: workspace)
            InkRule(vertical: false)
            HStack {
                Text("changes").microLabel()
                Text("\(files.count)").font(.mono(11, .medium)).foregroundStyle(Ink.ink3)
                Spacer()
                let added = files.compactMap(\.additions).reduce(0, +)
                let removed = files.compactMap(\.deletions).reduce(0, +)
                if added + removed > 0 {
                    Text("+\(added)").font(.mono(11)).foregroundStyle(Ink.leaf)
                    Text("−\(removed)").font(.mono(11)).foregroundStyle(Ink.berry)
                }
                Button { Task { await store.refreshChanges(workspace.id) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GhostButtonStyle())
                .help("refresh")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            InkRule(vertical: false)

            if files.isEmpty {
                VStack(spacing: 6) {
                    Text("no changes yet").font(.sans(13)).foregroundStyle(Ink.ink3)
                    Text("against \(workspace.baseRef)").font(.mono(11)).foregroundStyle(Ink.ink4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(files) { file in
                            FileRow(file: file, selected: store.openDiff[workspace.id]?.path == file.path) {
                                store.openDiff[workspace.id] = file
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Ink.paper2)
        .task(id: workspace.id) {
            // Catches edits made outside psyduck too, while the workspace is
            // open. The remote and GitHub are asked every eighth round only.
            var round = 0
            while !Task.isCancelled {
                await store.refreshChanges(workspace.id)
                await store.refreshBranch(workspace.id, network: round % 8 == 0)
                round += 1
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

private struct FileRow: View {
    let file: DiffFile
    let selected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(file.status == .untracked ? "A" : file.status.rawValue)
                    .font(.mono(10, .bold))
                    .foregroundStyle(file.status.color)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.fileName).font(.mono(12, selected ? .semibold : .regular)).lineLimit(1)
                    if !file.directory.isEmpty {
                        Text(file.directory).font(.mono(10)).foregroundStyle(Ink.ink3)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if let a = file.additions, let d = file.deletions {
                    Text("+\(a)").font(.mono(10)).foregroundStyle(Ink.leaf)
                    Text("−\(d)").font(.mono(10)).foregroundStyle(Ink.berry)
                } else if file.status == .untracked {
                    Text("new").font(.mono(10)).foregroundStyle(Ink.leaf)
                } else {
                    Text("bin").font(.mono(10)).foregroundStyle(Ink.ink3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Ink.paper : .clear))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.ink, lineWidth: Ink.border)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The top-right corner: the one next step for this branch — pull, commit &
/// push, create a PR, ready it for review — chosen by `PrimaryAction.decide`.
private struct PrimaryActionBar: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace

    var body: some View {
        let action = store.primaryAction(for: workspace.id)
        let busy = store.acting.contains(workspace.id)
        let running = store.isRunning(workspace.id)
        let state = store.branches[workspace.id]

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.branch).font(.mono(11, .medium)).lineLimit(1).truncationMode(.middle)
                Text(summary(state)).font(.mono(10)).foregroundStyle(Ink.ink3).lineLimit(1)
            }
            Spacer(minLength: 6)
            if busy { ProgressView().controlSize(.small) }
            Button {
                store.perform(action, on: workspace.id)
            } label: {
                HStack(spacing: 4) {
                    Text(action.title)
                    if case .viewPR = action { Image(systemName: "arrow.up.right") }
                    if case .merged = action { Image(systemName: "arrow.up.right") }
                }
            }
            .buttonStyle(InkButtonStyle(fill: fill(action), small: true))
            // Committing under claude's feet would race its edits.
            .disabled(action == .none || busy || (running && action.touchesWorkTree))
            .help(running && action.touchesWorkTree ? "wait for claude to finish" : action.help)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func fill(_ action: PrimaryAction) -> Color {
        switch action {
        case .createPR, .commitAndPush, .commit, .push: return Ink.accent
        case .pull: return Ink.amber
        case .markReady: return Ink.acid
        case .viewPR, .merged, .none: return Ink.paper
        }
    }

    private func summary(_ state: BranchState?) -> String {
        guard let state else { return "checking…" }
        var parts: [String] = []
        if state.dirty { parts.append("uncommitted") }
        if state.ahead > 0 { parts.append("↑\(state.ahead)") }
        if state.behind > 0 { parts.append("↓\(state.behind)") }
        if !state.hasUpstream && state.commitsSinceBase > 0 { parts.append("not pushed") }
        if let pr = state.pr {
            parts.append("pr #\(pr.number) \(pr.isDraft ? "draft" : pr.state.lowercased())")
        }
        if !state.hasRemote { parts.append("no remote") }
        return parts.isEmpty ? "\(state.commitsSinceBase) commits since base" : parts.joined(separator: " · ")
    }
}

extension PrimaryAction {
    /// Actions that change files or history in the worktree.
    var touchesWorkTree: Bool {
        switch self {
        case .pull, .commit, .commitAndPush: return true
        default: return false
        }
    }
}
