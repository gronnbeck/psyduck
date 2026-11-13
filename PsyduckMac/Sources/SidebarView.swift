import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var updater: UpdaterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("psyduck").font(.display(17))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 34) // clear the traffic lights
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.repos) { repo in
                        RepoSection(repo: repo)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }

            InkRule(vertical: false)
            HStack(spacing: 2) {
                AddRepoButtons(compact: true)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(GhostButtonStyle())
                .help("settings")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Ink.paper2)
    }
}

private struct RepoSection: View {
    @EnvironmentObject private var store: AppStore
    let repo: Repo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(repo.name).microLabel()
                Spacer()
                if store.creating.contains(repo.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { Task { await store.newWorkspace(in: repo) } } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("new workspace in \(repo.name)")
                }
            }
            .padding(.leading, 6)
            .contextMenu {
                Button("reveal in finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.path) }
                Button("remove from psyduck") { store.removeRepo(repo) }
            }

            let workspaces = store.workspaces(in: repo)
            if workspaces.isEmpty {
                Button("new workspace →") { Task { await store.newWorkspace(in: repo) } }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(store.creating.contains(repo.id))
            }
            ForEach(workspaces) { workspace in
                WorkspaceRow(workspace: workspace)
            }
        }
    }
}

private struct WorkspaceRow: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace

    var body: some View {
        let selected = store.selection == workspace.id
        let count = store.changes[workspace.id]?.count ?? 0
        Button { store.selection = workspace.id } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.isRunning(workspace.id) ? Ink.leaf : Ink.ink4)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name).font(.sans(13, selected ? .semibold : .regular))
                    Text(workspace.branch).font(.mono(10)).foregroundStyle(Ink.ink3).lineLimit(1)
                }
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.mono(10, .medium)).foregroundStyle(Ink.ink3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Ink.paper)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Ink.ink, lineWidth: Ink.border))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("reveal worktree in finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path) }
            Button("copy worktree path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.path, forType: .string)
            }
            Divider()
            Button("archive (remove worktree, keep branch)") { Task { await store.archive(workspace) } }
        }
    }
}
