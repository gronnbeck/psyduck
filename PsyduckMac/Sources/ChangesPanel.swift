import PsyduckCore
import SwiftUI

/// The right-hand panel: the branch's next step (top right), every file the
/// workspace changed since its base, and Discard / Commit while there's
/// uncommitted work. Clicking a file opens its diff in a tab beside the
/// session.
struct ChangesPanel: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    @State private var confirmDiscard = false

    private var files: [DiffFile] { store.changes[workspace.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader {
                Text("Changes").sectionLabel()
                Text("\(files.count)")
                    .font(.mono(12, .medium))
                    .foregroundStyle(files.isEmpty ? Tk.inkMuted : Tk.onBrand)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(files.isEmpty ? Tk.bg300 : Tk.brand))
                Spacer(minLength: 4)
                Button { Task { await store.refreshChanges(workspace.id); await store.refreshBranch(workspace.id, network: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.tkIcon())
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh changes (⌘R)")
                PrimaryActionButton(workspace: workspace)
            }

            if files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.ellipsis")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Tk.inkMuted, Tk.brand)
                    Text("No changes yet").font(.display(22))
                    (Text("Nothing differs from ") + Text(workspace.baseRef).font(.mono(12)).foregroundColor(Tk.ink)
                        + Text(". Ask Claude to poke at something and diffs land here."))
                        .font(.sans(13))
                        .lineSpacing(3)
                        .foregroundStyle(Tk.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let active = store.activeDiff[workspace.id]
                ScrollView {
                    // Lazy: a branch can touch thousands of files.
                    LazyVStack(spacing: 2) {
                        ForEach(files) { file in
                            FileRow(file: file, selected: active == file.path) {
                                store.openDiff(file.path, in: workspace.id)
                            }
                            .equatable()
                        }
                    }
                    .padding(8)
                }
            }

            if store.branches[workspace.id]?.dirty == true && !files.isEmpty {
                Hairline()
                HStack(spacing: 8) {
                    Button { confirmDiscard = true } label: { Text("Discard").frame(maxWidth: .infinity) }
                        .buttonStyle(.tkSecondary)
                    Button { store.commitOnly(workspace.id) } label: {
                        HStack(spacing: 6) { Text("Commit"); Kbd(keys: "⌘S", onBrand: true) }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.tkPrimary)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Commit everything with a message Claude writes. Doesn't push.")
                }
                .disabled(store.acting.contains(workspace.id) || store.isRunning(workspace.id))
                .padding(12)
            }
        }
        .background(Tk.bg100)
        .confirmationDialog("Discard every uncommitted change in \(workspace.name)?",
                            isPresented: $confirmDiscard) {
            Button("Discard changes", role: .destructive) { store.discard(workspace.id) }
        } message: {
            Text("Untracked files are deleted too. Commits stay.")
        }
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

/// The top-right button: the one next step for this branch, chosen by
/// `PrimaryAction.decide` — pull, commit & push, create a PR, ready it.
private struct PrimaryActionButton: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace

    var body: some View {
        let action = store.primaryAction(for: workspace.id)
        let busy = store.acting.contains(workspace.id)
        let blocked = store.isRunning(workspace.id) && action.touchesWorkTree

        Button {
            store.perform(action, on: workspace.id)
        } label: {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon(action)).font(.system(size: 12, weight: .medium))
                }
                Text(action.title)
            }
        }
        .buttonStyle(TkButtonStyle(kind: emphasised(action) ? .primary : .secondary))
        .disabled(action == .none || busy || blocked)
        .help(blocked ? "Wait for Claude to finish" : action.help)
    }

    private func emphasised(_ action: PrimaryAction) -> Bool {
        switch action {
        case .pull, .markReady: return true
        default: return false
        }
    }

    private func icon(_ action: PrimaryAction) -> String {
        switch action {
        case .pull: return "arrow.down"
        case .commit, .commitAndPush, .push: return "arrow.up"
        case .createPR, .none: return "arrow.triangle.pull"
        case .markReady: return "checkmark"
        case .viewPR, .merged: return "arrow.up.right"
        }
    }
}

private struct FileRow: View, Equatable {
    let file: DiffFile
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false

    /// What it shows, so an unchanged row is left alone when the store moves.
    static func == (a: FileRow, b: FileRow) -> Bool { a.file == b.file && a.selected == b.selected }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(file.status.letter)
                    .font(.mono(11, .semibold))
                    .foregroundStyle(file.status.color)
                    .frame(width: 12)
                (Text(file.fileName).foregroundColor(Tk.ink)
                    + Text(file.directory.isEmpty ? "" : "  " + file.directory.dropLast()).foregroundColor(Tk.inkFaint))
                    .font(.sans(13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let a = file.additions, let d = file.deletions {
                    Text("+\(a)").foregroundStyle(Tk.success)
                    Text("−\(d)").foregroundStyle(Tk.danger)
                } else if file.status == .untracked {
                    Text("new").foregroundStyle(Tk.success)
                } else {
                    Text("bin").foregroundStyle(Tk.inkFaint)
                }
            }
            .font(.mono(12))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Tk.radiusMd).fill(selected || hovering ? Tk.bg300 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
