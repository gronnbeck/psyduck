import AppKit
import PsyduckCore
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
        .sheet(item: $store.renaming) { RenameSheet(workspace: $0) }
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

/// Renames a workspace. Its branch is renamed with it.
private struct RenameSheet: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    @State private var name = ""
    @State private var problem: String?
    @State private var busy = false

    private var cleaned: String { Workspace.cleanName(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename workspace").font(.display(22))
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.sans(12, .medium)).foregroundStyle(Tk.inkMuted)
                TkTextField(text: $name, placeholder: workspace.name)
                    .onSubmit(rename)
                Text("Branch: \(Workspace.branchName(for: cleaned.isEmpty ? workspace.name : cleaned))")
                    .font(.mono(12)).foregroundStyle(Tk.inkFaint)
                Text("The branch is renamed too. The worktree folder stays where it is.")
                    .font(.sans(12)).foregroundStyle(Tk.inkFaint)
                if let problem {
                    Text(problem).font(.sans(12)).foregroundStyle(Tk.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { store.renaming = nil }.buttonStyle(.tkGhost)
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "Renaming…" : "Rename", action: rename)
                    .buttonStyle(.tkPrimary)
                    .disabled(busy || cleaned.isEmpty || cleaned == workspace.name)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Tk.bg200)
        .onAppear { name = workspace.name }
    }

    private func rename() {
        guard !busy, !cleaned.isEmpty else { return }
        busy = true
        Task {
            problem = await store.rename(workspace, to: name)
            busy = false
            if problem == nil { store.renaming = nil }
        }
    }
}

/// The session, and any diffs opened from the changes panel as tabs beside it.
private struct CenterPane: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace

    var body: some View {
        let files = store.changes[workspace.id] ?? []
        let tabs = (store.diffTabs[workspace.id] ?? []).compactMap { path in files.first { $0.path == path } }
        let active = tabs.first { $0.path == store.activeDiff[workspace.id] }

        VStack(spacing: 0) {
            if !tabs.isEmpty {
                DiffTabs(workspace: workspace, tabs: tabs, active: active?.path)
            }
            ZStack {
                // The session stays alive under a diff, so what you were
                // typing and where you had scrolled to are still there.
                ChatView(workspace: workspace)
                    .opacity(active == nil ? 1 : 0)
                    .disabled(active != nil)
                    .accessibilityHidden(active != nil)
                if let active {
                    DiffView(workspace: workspace, file: active).id(active.path)
                }
            }
        }
    }
}

/// The tab strip over the center pane: the session first, then one tab per
/// open diff.
private struct DiffTabs: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    let tabs: [DiffFile]
    let active: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Tab(active: active == nil, help: "The session with Claude") {
                            store.activeDiff[workspace.id] = nil
                        } label: {
                            Image(systemName: "bubble.left").font(.system(size: 11, weight: .medium))
                            Text("Session").font(.sans(12, .medium))
                        }
                        ForEach(tabs) { file in
                            Tab(active: active == file.path, help: file.path) {
                                store.activeDiff[workspace.id] = file.path
                            } close: {
                                store.closeDiff(file.path, in: workspace.id)
                            } label: {
                                Text(file.status.letter).font(.mono(11, .semibold)).foregroundStyle(file.status.color)
                                Text(file.fileName).font(.mono(12, .medium))
                            }
                            .id(file.path)
                        }
                    }
                }
                .onChange(of: active) { if let active { proxy.scrollTo(active) } }
            }
            .frame(height: 36)
            .background(Tk.bg100)
            Hairline()
        }
    }
}

private struct Tab<Label: View>: View {
    let active: Bool
    let help: String
    let select: () -> Void
    var close: (() -> Void)?
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 6) { label }
                    .lineLimit(1)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Tk.bg300 : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tk.inkMuted)
                .opacity(active || hovering ? 1 : 0)
                .accessibilityLabel("Close \(help)")
            }
        }
        .foregroundStyle(active ? Tk.ink : Tk.inkMuted)
        .padding(.leading, 14)
        .padding(.trailing, close == nil ? 14 : 8)
        .frame(height: 36)
        .background(active ? Tk.bg000 : (hovering ? Tk.bg200 : .clear))
        .overlay(alignment: .top) { Rectangle().fill(active ? Tk.brand : .clear).frame(height: 2) }
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
        .onHover { hovering = $0 }
        .help(help)
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
                if let host = store.host(of: workspace) {
                    MirrorStatus(workspace: workspace, host: host)
                }
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

/// In the status bar of a host's workspace: which host it is on, and where
/// its copy on this Mac stands. Click to copy now.
private struct MirrorStatus: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    let host: RemoteHost

    var body: some View {
        Button { Task { await store.mirror(workspace.id) } } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack").font(.system(size: 10))
                Text(label)
            }
            .foregroundStyle(failed ? Tk.danger : Tk.inkMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.mirrors[workspace.id] == .syncing)
        .help(help)
    }

    private var failed: Bool {
        if case .failed = store.mirrors[workspace.id] { return true }
        return false
    }

    private var label: String {
        switch store.mirrors[workspace.id] {
        case .syncing: return "\(host.displayName) · copying files…"
        case .synced(let date, _): return "\(host.displayName) · copied \(date.formatted(date: .omitted, time: .shortened))"
        case .failed: return "\(host.displayName) · copy failed"
        case nil: return "\(host.displayName) · copy files here"
        }
    }

    private var help: String {
        let place = store.mirrorDirectory(for: workspace)?.path ?? ""
        switch store.mirrors[workspace.id] {
        case .failed(let reason): return "\(reason). Click to try again."
        case .synced(_, let result):
            var parts = ["\(result.copied) copied, \(result.removed) removed, into \(place)."]
            if !result.skipped.isEmpty { parts.append("Left out: " + result.skipped.prefix(5).joined(separator: "; ")) }
            return parts.joined(separator: " ") + " Click to copy again."
        default: return "Copy this workspace's files to \(place)"
        }
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

/// Asks for a repo's URL and clones it, on this Mac or on `host`.
struct CloneSheet: View {
    @EnvironmentObject private var store: AppStore
    let host: RemoteHost?
    @Binding var isPresented: Bool
    @State private var url = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(host.map { "Clone a repo on \($0.displayName)" } ?? "Clone a repo").font(.display(22))
            VStack(alignment: .leading, spacing: 6) {
                Text("Repository URL").font(.sans(12, .medium)).foregroundStyle(Tk.inkMuted)
                TkTextField(text: $url, placeholder: "https://github.com/owner/repo.git")
                    .onSubmit(clone)
                Text(host == nil ? "Goes to \(store.settings.reposRoot)/<name>"
                                 : "The host clones it with its own git login, into its repos folder.")
                    .font(.mono(12)).foregroundStyle(Tk.inkFaint)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { isPresented = false }.buttonStyle(.tkGhost)
                Button(busy ? "Cloning…" : "Clone", action: clone)
                    .buttonStyle(.tkPrimary)
                    .disabled(busy || url.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Tk.bg200)
    }

    private func clone() {
        guard !url.isEmpty, !busy else { return }
        busy = true
        Task {
            await store.cloneRepo(url, on: host)
            busy = false
            isPresented = false
        }
    }
}

/// "Add repo" and "Clone".
struct AddRepoButtons: View {
    @EnvironmentObject private var store: AppStore
    @State private var cloning = false
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
        .sheet(isPresented: $cloning) { CloneSheet(host: nil, isPresented: $cloning) }
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
