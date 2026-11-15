import Foundation
import PsyduckCore
import SwiftUI

/// Everything the window shows. The work — repos, worktrees, claude turns,
/// event logs — is the engine's; this mirrors its state for SwiftUI and
/// keeps what only the window cares about (selection, the open diff).
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

    @Published private(set) var changes: [UUID: [DiffFile]] = [:]
    /// Each workspace's branch against its remote and PR, for the header button.
    @Published var branches: [UUID: BranchState] = [:]
    /// Workspaces with a header action (commit, push, PR…) in flight.
    @Published var acting: Set<UUID> = []
    /// The file opened wide in the center pane, per workspace.
    @Published var openDiff: [UUID: DiffFile] = [:]
    /// The file whose diff shows inline in the changes panel, per workspace.
    @Published var selectedFile: [UUID: DiffFile] = [:]
    @Published private(set) var creating: Set<UUID> = []

    let settings: AppSettings
    let engine: WorkspaceEngine
    /// One listener per workspace, feeding its events into `transcripts`.
    private var listeners: [UUID: Task<Void, Never>] = [:]

    init(settings: AppSettings, stateURL: URL? = EngineStorage.defaultStateURL()) {
        self.settings = settings
        let storage = EngineStorage(stateURL: stateURL)
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
        repos = snapshot.repos
        workspaces = snapshot.workspaces
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

    private func forget(_ id: UUID) {
        listeners[id]?.cancel()
        listeners[id] = nil
        transcripts[id] = nil
        changes[id] = nil
        branches[id] = nil
        openDiff[id] = nil
        selectedFile[id] = nil
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

    /// Removes the worktree and forgets the workspace. The branch is kept.
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
        changes[id] = files
        if let open = openDiff[id], !files.contains(where: { $0.path == open.path }) {
            openDiff[id] = nil
        }
    }

    /// One file's unified diff against the workspace's base commit.
    func diff(of file: DiffFile, in workspace: Workspace) async throws -> String {
        try await engine.diff(of: file, in: workspace.id)
    }
}
