import AppKit
import SwiftUI

/// The window, laid out as the Tinker design: workspaces on the left, the
/// session in the middle, changes on the right, a status bar along the bottom.
struct ShellView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 248)
                Hairline(vertical: true)
                if store.showingSettings {
                    SettingsView()
                } else if let workspace = store.selectedWorkspace {
                    HSplitView {
                        CenterPane(workspace: workspace)
                            .frame(minWidth: 460, maxWidth: .infinity)
                        ChangesPanel(workspace: workspace)
                            .frame(minWidth: 280, idealWidth: 340, maxWidth: 720)
                    }
                    .id(workspace.id)
                } else {
                    NoWorkspaceView()
                }
            }
            Hairline()
            StatusBar()
        }
        .background(Tk.bg000)
        .foregroundStyle(Tk.ink)
        .ignoresSafeArea()
        .alert("psyduck", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

/// The chat, or a diff opened full-width from the changes panel.
private struct CenterPane: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace

    var body: some View {
        if let file = store.openDiff[workspace.id] {
            DiffView(workspace: workspace, file: file)
        } else {
            ChatView(workspace: workspace)
        }
    }
}

/// The 24px strip along the bottom: branch, base commit, what's uncommitted,
/// and what the session has cost.
private struct StatusBar: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 16) {
            if let workspace = store.selectedWorkspace {
                Text("git:\(workspace.branch)")
                Text(workspace.baseCommit.prefix(7))
                if let state = store.branches[workspace.id] {
                    let dirty = store.changes[workspace.id]?.count ?? 0
                    if state.dirty && dirty > 0 {
                        Text("\(dirty) uncommitted").foregroundStyle(Tk.warning)
                    }
                    if state.ahead > 0 { Text("↑\(state.ahead)") }
                    if state.behind > 0 { Text("↓\(state.behind)").foregroundStyle(Tk.warning) }
                }
                Spacer()
                if let cost = workspace.totalCost {
                    Text(String(format: "session $%.3f", cost))
                }
            } else {
                Text("psyduck")
                Spacer()
            }
        }
        .font(.mono(12, .medium))
        .foregroundStyle(Tk.inkMuted)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Tk.bg100)
    }
}

private struct NoWorkspaceView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if let repo = store.repos.first {
            EmptyPane(title: "Start a workspace",
                      message: "A workspace is a fresh git worktree on its own branch, with Claude running inside it. Your checkout stays untouched.") {
                Button { Task { await store.newWorkspace(in: repo) } } label: {
                    HStack(spacing: 8) { Text("New workspace in \(repo.name)"); Kbd(keys: "⌘N", onBrand: true) }
                }
                .buttonStyle(.tkPrimary)
                .disabled(store.creating.contains(repo.id))
            }
        } else {
            EmptyPane(title: "Ship it, little gremlin",
                      message: "Add a git repository to start. Every chat gets its own worktree, so nothing touches your checkout.") {
                AddRepoButtons()
            }
        }
    }
}

/// "Add repo" and "Clone".
struct AddRepoButtons: View {
    @EnvironmentObject private var store: AppStore
    @State private var cloning = false
    @State private var url = ""
    @State private var busy = false
    var compact = false

    var body: some View {
        Group {
            if compact {
                Button { pickFolder() } label: {
                    HStack(spacing: 6) { Image(systemName: "plus"); Text("Add repo") }.fixedSize()
                }
                .buttonStyle(.tkGhost)
                Button { cloning = true } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.down.to.line"); Text("Clone") }.fixedSize()
                }
                .buttonStyle(.tkGhost)
            } else {
                HStack(spacing: 10) {
                    Button("Add local repo") { pickFolder() }.buttonStyle(.tkPrimary)
                    Button("Clone from URL") { cloning = true }.buttonStyle(.tkSecondary)
                }
            }
        }
        .sheet(isPresented: $cloning) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Clone a repo").font(.display(22))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Repository URL").font(.sans(12, .medium)).foregroundStyle(Tk.inkMuted)
                    TkTextField(text: $url, placeholder: "https://github.com/owner/repo.git")
                        .onSubmit(clone)
                    Text("Goes to \(store.settings.reposRoot)/<name>").font(.mono(12)).foregroundStyle(Tk.inkFaint)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { cloning = false }.buttonStyle(.tkGhost)
                    Button(busy ? "Cloning…" : "Clone", action: clone)
                        .buttonStyle(.tkPrimary)
                        .disabled(busy || url.isEmpty)
                }
            }
            .padding(24)
            .frame(width: 480)
            .background(Tk.bg200)
        }
    }

    private func clone() {
        guard !url.isEmpty else { return }
        busy = true
        Task {
            await store.cloneRepo(url)
            busy = false
            cloning = false
            url = ""
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repo"
        panel.message = "Choose a git repository"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await store.addRepo(at: url.path) }
        }
    }
}

/// Tinker's input: raised surface, strong border, mono.
struct TkTextField: View {
    @Binding var text: String
    var placeholder: String
    var mono = true

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Tk.inkFaint))
            .textFieldStyle(.plain)
            .font(mono ? .mono(12) : .sans(13))
            .foregroundStyle(Tk.ink)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .tkCard(Tk.radiusMd, fill: Tk.bg200, border: Tk.lineStrong)
    }
}
