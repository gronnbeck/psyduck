import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    /// "New workspace" goes to the repo you're in, else the first one.
    private var targetRepo: Repo? {
        store.selectedWorkspace.flatMap(store.repo(for:)) ?? store.repos.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights sit in this row, so the wordmark starts after them.
            PaneHeader(leading: 80) {
                HStack(spacing: 0) {
                    Text("psyduck").font(.display(22)).tracking(-0.4)
                    Text(".").font(.display(22)).foregroundStyle(Tk.brand)
                }
                Spacer()
            }

            Button {
                if let repo = targetRepo { Task { await store.newWorkspace(in: repo) } }
            } label: {
                HStack {
                    Label("New workspace", systemImage: "plus")
                    Spacer()
                    Kbd(keys: "⌘N")
                }
            }
            .buttonStyle(.tkSecondary)
            .disabled(targetRepo == nil || targetRepo.map { store.creating.contains($0.id) } == true)
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.repos) { repo in
                        RepoSection(repo: repo)
                    }
                }
                .padding(.bottom, 16)
            }

            Hairline()
            HStack(spacing: 4) {
                AddRepoButtons(compact: true)
                Spacer()
                Button { store.showingSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.tkIcon())
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
            }
            .padding(8)
        }
        .background(Tk.bg100)
    }
}

private struct RepoSection: View {
    @EnvironmentObject private var store: AppStore
    let repo: Repo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(repo.name).sectionLabel()
                Spacer()
                if store.creating.contains(repo.id) {
                    ProgressView().controlSize(.mini).frame(width: 28, height: 28)
                } else {
                    Button { Task { await store.newWorkspace(in: repo) } } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.tkIcon(28))
                    .help("Add workspace to \(repo.name)")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contextMenu {
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.path) }
                Button("Remove from psyduck") { store.removeRepo(repo) }
            }

            VStack(spacing: 2) {
                ForEach(store.workspaces(in: repo)) { workspace in
                    WorkspaceRow(workspace: workspace)
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

private struct WorkspaceRow: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    @State private var hovering = false

    var body: some View {
        let selected = store.selection == workspace.id && !store.showingSettings
        let running = store.isRunning(workspace.id)
        Button {
            store.selection = workspace.id
            store.showingSettings = false
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(workspace.name).font(.sans(13, .semibold)).foregroundStyle(Tk.ink)
                    Text(workspace.branch).font(.mono(12)).foregroundStyle(Tk.inkMuted).lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Circle().fill(running ? Tk.info : Tk.success).frame(width: 8, height: 8)
                    Text(running ? "Running" : "Ready").font(.sans(12)).foregroundStyle(Tk.inkMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Tk.radiusMd, style: .continuous)
                    .fill(selected || hovering ? Tk.bg300 : .clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Tk.brand).frame(width: 3).padding(.vertical, 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { WorkspaceMenuItems(workspace: workspace) }
    }
}

/// Shared by the row's context menu and the session header's "…" menu.
struct WorkspaceMenuItems: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace

    var body: some View {
        Button("Reveal worktree in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path) }
        Button("Copy worktree path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.path, forType: .string)
        }
        Divider()
        Button("Archive (remove worktree, keep branch)") { Task { await store.archive(workspace) } }
    }
}
