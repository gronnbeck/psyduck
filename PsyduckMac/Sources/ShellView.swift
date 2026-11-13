import AppKit
import SwiftUI

/// The window: repos and workspaces on the left, the chat (or an open diff)
/// in the middle, the workspace's changed files on the right.
struct ShellView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 250)
            InkRule()
            if store.showingSettings {
                SettingsView()
            } else if let workspace = store.selectedWorkspace {
                HSplitView {
                    CenterPane(workspace: workspace)
                        .frame(minWidth: 460, maxWidth: .infinity)
                    ChangesPanel(workspace: workspace)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 520)
                }
                .id(workspace.id)
            } else {
                NoWorkspaceView()
            }
        }
        .background(Ink.paper)
        .foregroundStyle(Ink.ink)
        // The np.lol palette is light only; a dark system appearance would
        // otherwise leak into text fields and pickers.
        .preferredColorScheme(.light)
        .alert("psyduck", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("ok") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

/// The chat, or a diff when a file is open from the changes panel.
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

private struct NoWorkspaceView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if let repo = store.repos.first {
            EmptyPane(title: "psyduck",
                      message: "a workspace is a fresh git worktree on its own branch, with claude running inside it.") {
                Button("new workspace in \(repo.name) →") { Task { await store.newWorkspace(in: repo) } }
                    .buttonStyle(InkButtonStyle())
                    .disabled(store.creating.contains(repo.id))
            }
        } else {
            EmptyPane(title: "psyduck",
                      message: "add a git repository to start. each chat gets its own worktree, so nothing touches your checkout.") {
                AddRepoButtons()
            }
        }
    }
}

/// "add local repo" and "clone from url".
struct AddRepoButtons: View {
    @EnvironmentObject private var store: AppStore
    @State private var cloning = false
    @State private var url = ""
    @State private var busy = false
    var compact = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 4) {
                    Button { pickFolder() } label: { Label("add repo", systemImage: "plus") }
                    Button { cloning = true } label: { Label("clone", systemImage: "arrow.down.circle") }
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                HStack(spacing: 10) {
                    Button("add local repo →") { pickFolder() }.buttonStyle(InkButtonStyle())
                    Button("clone from url") { cloning = true }.buttonStyle(InkButtonStyle(fill: Ink.paper))
                }
            }
        }
        .sheet(isPresented: $cloning) {
            VStack(alignment: .leading, spacing: 12) {
                Text("clone a repo").font(.sans(16, .semibold))
                TextField("https://github.com/owner/repo.git", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.mono(12))
                    .frame(width: 420)
                    .onSubmit(clone)
                Text("goes to \(store.settings.reposRoot)/<name>").font(.mono(11)).foregroundStyle(Ink.ink3)
                HStack {
                    Spacer()
                    Button("cancel") { cloning = false }.buttonStyle(GhostButtonStyle())
                    Button(busy ? "cloning…" : "clone →", action: clone)
                        .buttonStyle(InkButtonStyle(small: true))
                        .disabled(busy || url.isEmpty)
                }
            }
            .padding(20)
            .background(Ink.paper)
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
