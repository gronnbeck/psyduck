import Foundation
import PsyduckCore
import SwiftUI

/// Everything the window shows. The work — repos, worktrees, claude turns,
/// event logs — is the engine's; this mirrors its state for SwiftUI and
/// keeps what only the window cares about (selection, the open diff tabs).
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []
    @Published private(set) var workspaces: [Workspace] = []
    /// Each workspace's chat and session state, built from its events.
    @Published private(set) var transcripts: [UUID: Transcript] = [:]
    @Published var selection: UUID?
    @Published var errorMessage: String?
    /// Settings is a page in the main window, over the chat and changes panes.
    @Published var showingSettings = false
    /// The workspace whose rename sheet is open.
    @Published var renaming: Workspace?

    @Published private(set) var changes: [UUID: [DiffFile]] = [:]
    /// Each workspace's branch against its remote and PR, for the header button.
    @Published var branches: [UUID: BranchState] = [:]
    /// Workspaces with a header action (commit, push, PR…) in flight.
    @Published var acting: Set<UUID> = []
    /// Diffs open as tabs beside the session: the files' paths, in the order
    /// they were opened.
    @Published private(set) var diffTabs: [UUID: [String]] = [:]
    /// The tab in front, by path. Nil is the session.
    @Published var activeDiff: [UUID: String] = [:]
    @Published private(set) var creating: Set<UUID> = []

    let settings: AppSettings
    let engine: WorkspaceEngine
    /// One listener per workspace, feeding its events into `transcripts`.
    private var listeners: [UUID: Task<Void, Never>] = [:]
    private let storage: EngineStorage
    /// Streamed tokens not yet shown, and the workspaces about to show theirs.
    private var pendingDeltas: [UUID: [WorkspaceEvent]] = [:]
    private var flushing: Set<UUID> = []

    init(settings: AppSettings, stateURL: URL? = EngineStorage.defaultStateURL()) {
        self.settings = settings
        let storage = EngineStorage(stateURL: stateURL)
        self.storage = storage
        let loaded = storage.load()
        engine = WorkspaceEngine(loaded: loaded, storage: storage) { await settings.config }
        repos = loaded.repos
        workspaces = loaded.workspaces
        transcripts = loaded.events.mapValues { Transcript(events: $0) }
        selection = workspaces.first?.id
        for workspace in workspaces { listen(to: workspace.id) }
    }

    // MARK: - Lookup

    var selectedWorkspace: Workspace? { workspaces.first { $0.id == selection } }

    func repo(for workspace: Workspace) -> Repo? { repos.first { $0.id == workspace.repoID } }

    func workspaces(in repo: Repo) -> [Workspace] {
        workspaces.filter { $0.repoID == repo.id }.sorted { $0.createdAt > $1.createdAt }
    }

    func transcript(_ id: UUID) -> Transcript { transcripts[id] ?? Transcript() }

    func isRunning(_ id: UUID) -> Bool { transcripts[id]?.running ?? false }

    // MARK: - Engine state

    /// Takes the engine's repos and workspaces as the truth.
    private func sync() async {
        let snapshot = await engine.snapshot()
        // Say so only when something changed, or the whole window redraws.
        if repos != snapshot.repos { repos = snapshot.repos }
        if workspaces != snapshot.workspaces { workspaces = snapshot.workspaces }
        let alive = Set(workspaces.map(\.id))
        for id in listeners.keys where !alive.contains(id) { forget(id) }
        if selectedWorkspace == nil { selection = workspaces.first?.id }
    }

    /// Follows a workspace's events from where its transcript left off.
    private func listen(to id: UUID) {
        guard listeners[id] == nil else { return }
        let since = transcripts[id]?.lastSeq ?? 0
        listeners[id] = Task { [weak self, engine] in
            for await event in await engine.events(for: id, since: since) {
                guard let self else { return }
                self.receive(event, for: id)
            }
        }
    }

    private func receive(_ event: WorkspaceEvent, for id: UUID) {
        if case .textDelta = event.kind {
            // Tokens arrive far faster than the window needs redrawing.
            pendingDeltas[id, default: []].append(event)
            if flushing.insert(id).inserted {
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    flushing.remove(id)
                    flush(id)
                }
            }
            return
        }
        // Anything else goes after the tokens that came before it.
        flush(id)
        transcripts[id, default: Transcript()].apply(event)
        switch event.kind {
        case .toolResult:
            // Edits land while claude works; keep the panel close behind.
            Task { await refreshChanges(id) }
        case .turnResult, .turnEnded:
            // The session id and cost live on the workspace.
            Task {
                await sync()
                await refreshChanges(id)
            }
        default:
            break
        }
    }

    /// Shows the tokens held back since the last redraw.
    private func flush(_ id: UUID) {
        guard let events = pendingDeltas.removeValue(forKey: id), var transcript = transcripts[id] else { return }
        for event in events { transcript.apply(event) }
        transcripts[id] = transcript
    }

    private func forget(_ id: UUID) {
        listeners[id]?.cancel()
        listeners[id] = nil
        pendingDeltas[id] = nil
        transcripts[id] = nil
        changes[id] = nil
        branches[id] = nil
        diffTabs[id] = nil
        activeDiff[id] = nil
    }

    // MARK: - Repos

    /// Adds a local repository. Any directory inside it works; the repo's
    /// top level is what's stored.
    func addRepo(at path: String) async {
        do {
            try await engine.addRepo(at: path)
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Clones `url` under the repos root, then adds it.
    func cloneRepo(_ url: String) async {
        do {
            try await engine.cloneRepo(url)
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forgets the repo. Its worktrees stay on disk.
    func removeRepo(_ repo: Repo) {
        Task {
            await engine.removeRepo(repo.id)
            await sync()
        }
    }

    // MARK: - Workspaces

    /// Makes a new worktree on a fresh `psyduck/<name>` branch cut from the
    /// repo's default branch, and selects it.
    func newWorkspace(in repo: Repo) async {
        creating.insert(repo.id)
        defer { creating.remove(repo.id) }
        do {
            let workspace = try await engine.newWorkspace(in: repo.id)
            await sync()
            listen(to: workspace.id)
            selection = workspace.id
            showingSettings = false
            await refreshChanges(workspace.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renames a workspace and its branch together. The worktree folder stays
    /// where it is. Returns what went wrong, or nil.
    @discardableResult
    func rename(_ workspace: Workspace, to raw: String) async -> String? {
        do {
            try await engine.rename(workspace.id, to: raw)
        } catch {
            return error.localizedDescription
        }
        await sync()
        await refreshBranch(workspace.id, network: false)
        return nil
    }

    /// Workspaces archived so far, from `archive.json`.
    func loadArchive() -> [Workspace] { storage.loadArchive() }

    /// Soft-deletes a workspace: the worktree goes, uncommitted work is saved
    /// to a ref, and the record moves to `archive.json`. The branch is kept.
    func archive(_ workspace: Workspace) async {
        do {
            try await engine.archive(workspace.id)
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Chat

    /// Sends one message. claude's turn streams into the transcript; a
    /// message sent while a turn is running waits for it to end.
    func send(_ text: String, to id: UUID) {
        Task { await engine.send(text, to: id) }
    }

    func stop(_ id: UUID) {
        Task { await engine.stop(id) }
    }

    // MARK: - Changes

    func refreshChanges(_ id: UUID) async {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        let files = await engine.changedFiles(id)
        guard workspaces.contains(where: { $0.id == id }) else { return }
        // Asked every few seconds; say so only when something changed, or
        // the whole window redraws for nothing.
        if changes[id] != files { changes[id] = files }
        let paths = Set(files.map(\.path))
        for gone in diffTabs[id] ?? [] where !paths.contains(gone) { closeDiff(gone, in: id) }
    }

    /// Opens a changed file's diff in a tab, or brings its tab to the front.
    func openDiff(_ path: String, in id: UUID) {
        if diffTabs[id]?.contains(path) != true { diffTabs[id, default: []].append(path) }
        activeDiff[id] = path
    }

    /// Closes a diff tab. If it was in front, its neighbour takes over, or
    /// the session when it was the last one.
    func closeDiff(_ path: String, in id: UUID) {
        guard var tabs = diffTabs[id], let index = tabs.firstIndex(of: path) else { return }
        tabs.remove(at: index)
        diffTabs[id] = tabs.isEmpty ? nil : tabs
        if activeDiff[id] == path { activeDiff[id] = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)] }
    }

    /// One file's unified diff against where the branch left its base.
    func diff(of file: DiffFile, in workspace: Workspace) async throws -> String {
        try await engine.diff(of: file, in: workspace.id)
    }
}
