import Combine
import Foundation
import PsyduckCore
import SwiftUI

/// Everything the window shows. The work — repos, worktrees, claude turns,
/// event logs — is an engine's: the one in this process, and one per remote
/// host. This mirrors their state for SwiftUI and keeps what only the window
/// cares about (selection, the open diff tabs).
@MainActor
final class AppStore: ObservableObject {
    /// Every engine's repos and workspaces: this Mac's first, then each
    /// host's in the order they're listed in settings.
    @Published private(set) var repos: [Repo] = []
    @Published private(set) var workspaces: [Workspace] = []
    /// Each workspace's chat and session state, built from its events.
    @Published private(set) var transcripts: [UUID: Transcript] = [:]
    @Published var selection: UUID? {
        didSet { if selection != oldValue { selectionChanged() } }
    }
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
    /// Where each host workspace's copy on this Mac stands.
    @Published private(set) var mirrors: [UUID: MirrorState] = [:]
    /// Workspaces whose copy went stale while it was being made.
    private var mirrorAgain: Set<UUID> = []
    /// Whether each remote host is connected, by host id.
    @Published private(set) var hostStatus: [UUID: RemoteEngine.Status] = [:]

    let settings: AppSettings
    /// The engine in this process, for this Mac's repos.
    let engine: WorkspaceEngine
    /// One listener per workspace, feeding its events into `transcripts`.
    private var listeners: [UUID: Task<Void, Never>] = [:]
    private let storage: EngineStorage
    /// Streamed tokens not yet shown, and the workspaces about to show theirs.
    private var pendingDeltas: [UUID: [WorkspaceEvent]] = [:]
    private var flushing: Set<UUID> = []

    /// A connected host: its engine, what it last said it has, and the task
    /// following its connection.
    private struct Remote {
        var host: RemoteHost
        var engine: RemoteEngine
        var snapshot = EngineSnapshot()
        var watcher: Task<Void, Never>?
    }
    private var remotes: [UUID: Remote] = [:]
    private var local = EngineSnapshot()
    /// Which host a repo is on. This Mac's repos aren't in it.
    private var repoHosts: [UUID: UUID] = [:]
    private let makeRemote: (RemoteHost) -> RemoteEngine
    private var hostsObserver: AnyCancellable?
    private var poller: Task<Void, Never>?

    /// `makeRemote` is how a host is reached; tests hand in engines joined
    /// to a server in the same process.
    init(settings: AppSettings, stateURL: URL? = EngineStorage.defaultStateURL(),
         makeRemote: @escaping (RemoteHost) -> RemoteEngine = { RemoteEngine(command: $0.command) }) {
        self.settings = settings
        self.makeRemote = makeRemote
        let storage = EngineStorage(stateURL: stateURL)
        self.storage = storage
        let loaded = storage.load()
        engine = WorkspaceEngine(loaded: loaded, storage: storage) { await settings.config }
        local = EngineSnapshot(repos: loaded.repos, workspaces: loaded.workspaces)
        repos = loaded.repos
        workspaces = loaded.workspaces
        transcripts = loaded.events.mapValues { Transcript(events: $0) }
        selection = workspaces.first?.id
        for workspace in workspaces { listen(to: workspace.id) }

        connect(to: settings.hosts)
        hostsObserver = settings.$hosts.dropFirst().sink { [weak self] hosts in
            Task { @MainActor in
                self?.connect(to: hosts)
                await self?.sync()
            }
        }
        // Hosts are also changed from other clients; ask now and then.
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if !self.remotes.isEmpty { await self.sync() }
            }
        }
    }

    deinit {
        poller?.cancel()
        for remote in remotes.values {
            remote.watcher?.cancel()
            let engine = remote.engine
            Task { await engine.shutDown() }
        }
    }

    // MARK: - Hosts

    /// Makes the connections match the hosts in settings: new ones are
    /// dialled, removed ones hung up, and a changed command redialled.
    private func connect(to hosts: [RemoteHost]) {
        let wanted = Dictionary(hosts.filter(\.isUsable).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, remote) in remotes where wanted[id]?.command != remote.host.command {
            remote.watcher?.cancel()
            let engine = remote.engine
            Task { await engine.shutDown() }
            remotes[id] = nil
            hostStatus[id] = nil
        }
        for (id, host) in wanted {
            if remotes[id] != nil {
                remotes[id]?.host = host
                continue
            }
            let engine = makeRemote(host)
            var remote = Remote(host: host, engine: engine)
            hostStatus[id] = .connecting
            remote.watcher = Task { [weak self] in
                await engine.start()
                for await status in engine.statuses {
                    guard let self else { return }
                    self.hostStatus[id] = status
                    if case .connected = status { await self.sync() }
                }
            }
            remotes[id] = remote
        }
    }

    /// Tries a host that's offline again, now.
    func reconnect(_ host: RemoteHost) {
        guard let engine = remotes[host.id]?.engine else { return }
        Task { await engine.reconnect() }
    }

    func isConnected(_ hostID: UUID) -> Bool {
        if case .connected = hostStatus[hostID] { return true }
        return false
    }

    /// The host a repo is on, or nil for this Mac.
    func host(of repo: Repo) -> RemoteHost? {
        repoHosts[repo.id].flatMap { remotes[$0]?.host }
    }

    /// The host a workspace is on, or nil for this Mac.
    func host(of workspace: Workspace) -> RemoteHost? {
        repoHosts[workspace.repoID].flatMap { remotes[$0]?.host }
    }

    /// This Mac's repos (`nil`), or a host's.
    func repos(on hostID: UUID?) -> [Repo] {
        repos.filter { repoHosts[$0.id] == hostID }
    }

    private func engine(forRepo id: UUID) -> any EngineClient {
        repoHosts[id].flatMap { remotes[$0]?.engine } ?? engine
    }

    func engine(for workspaceID: UUID) -> any EngineClient {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return engine }
        return engine(forRepo: workspace.repoID)
    }

    /// False when the workspace is on a host that can't be reached right now.
    private func reachable(_ workspaceID: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              let hostID = repoHosts[workspace.repoID] else { return true }
        return isConnected(hostID)
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

    /// Takes the engines' repos and workspaces as the truth. A host that
    /// can't be asked keeps what it last said: its workspaces are out of
    /// reach, not gone.
    private func sync() async {
        local = await engine.snapshot()
        for (id, remote) in remotes {
            guard let snapshot = try? await remote.engine.fetchSnapshot() else { continue }
            remotes[id]?.snapshot = snapshot
        }

        var allRepos = local.repos
        var allWorkspaces = local.workspaces
        var hosts: [UUID: UUID] = [:]
        for host in settings.hosts {
            guard let remote = remotes[host.id] else { continue }
            // A repo's id is its engine's own; this Mac's win a clash.
            let known = Set(allRepos.map(\.id))
            let theirs = remote.snapshot.repos.filter { !known.contains($0.id) }
            for repo in theirs { hosts[repo.id] = host.id }
            allRepos += theirs
            let theirIDs = Set(theirs.map(\.id))
            allWorkspaces += remote.snapshot.workspaces.filter { theirIDs.contains($0.repoID) }
        }
        repoHosts = hosts
        // Say so only when something changed, or the whole window redraws.
        if repos != allRepos { repos = allRepos }
        if workspaces != allWorkspaces { workspaces = allWorkspaces }

        let alive = Set(workspaces.map(\.id))
        for id in Set(listeners.keys).union(transcripts.keys) where !alive.contains(id) { forget(id) }
        for id in alive where reachable(id) { listen(to: id) }
        if selectedWorkspace == nil { selection = workspaces.first?.id }
    }

    /// Follows a workspace's events from where its transcript left off. A
    /// host's stream ends when the connection drops; the next `sync()` after
    /// it is back picks up from the last event seen.
    private func listen(to id: UUID) {
        guard listeners[id] == nil else { return }
        let since = transcripts[id]?.lastSeq ?? 0
        let engine = engine(for: id)
        listeners[id] = Task { [weak self] in
            for await event in await engine.events(for: id, since: since) {
                guard let self else { return }
                self.receive(event, for: id)
            }
            guard !Task.isCancelled, let self else { return }
            self.flush(id)
            self.listeners[id] = nil
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
            Task {
                await refreshChanges(id)
                await mirrorIfWanted(id)
            }
        case .turnResult, .turnEnded:
            // The session id and cost live on the workspace.
            Task {
                await sync()
                await refreshChanges(id)
                await mirrorIfWanted(id)
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
        mirrors[id] = nil
    }

    // MARK: - Copies of host workspaces

    /// A host workspace's copy on this Mac: being made, made, or failed.
    enum MirrorState: Equatable {
        case syncing
        case synced(Date, MirrorResult)
        case failed(String)
    }

    /// Where a host workspace is copied to on this Mac, or nil for a
    /// workspace that is already here.
    func mirrorDirectory(for workspace: Workspace) -> URL? {
        guard let host = host(of: workspace), let repo = repo(for: workspace) else { return nil }
        func safe(_ name: String) -> String {
            let cleaned = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty || cleaned.hasPrefix(".") ? "host" : cleaned
        }
        // The folder keeps the name the workspace was made with, as the
        // worktree on the host does, so a rename doesn't start a second copy.
        let folder = (workspace.path as NSString).lastPathComponent
        return URL(fileURLWithPath: (settings.mirrorsRoot as NSString).expandingTildeInPath)
            .appendingPathComponent(safe(host.displayName))
            .appendingPathComponent(safe(repo.name))
            .appendingPathComponent(safe(folder))
    }

    /// Copies a host workspace's files to this Mac now. One way: the host's
    /// files replace the copy's. Asked again while one runs, it runs once more
    /// after.
    func mirror(_ id: UUID) async {
        guard let workspace = workspaces.first(where: { $0.id == id }),
              let directory = mirrorDirectory(for: workspace),
              let remote = engine(for: id) as? RemoteEngine else { return }
        if mirrors[id] == .syncing {
            mirrorAgain.insert(id)
            return
        }
        mirrors[id] = .syncing
        repeat {
            mirrorAgain.remove(id)
            do {
                let result = try await remote.mirror(id, into: directory)
                mirrors[id] = .synced(Date(), result)
            } catch {
                mirrors[id] = .failed(error.localizedDescription)
                mirrorAgain.remove(id)
            }
        } while mirrorAgain.contains(id)
    }

    /// The automatic copy, when settings ask for one for this workspace.
    private func mirrorIfWanted(_ id: UUID) async {
        switch settings.mirrorMode {
        case "all": break
        case "open": guard selection == id else { return }
        default: return
        }
        guard reachable(id) else { return }
        await mirror(id)
    }

    /// Opening a session brings its copy up to date, in the "open" mode.
    func selectionChanged() {
        guard settings.mirrorMode == "open" || settings.mirrorMode == "all", let id = selection else { return }
        Task { await mirrorIfWanted(id) }
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

    /// Clones `url` under the repos root, then adds it: on this Mac, or on
    /// `host`.
    func cloneRepo(_ url: String, on host: RemoteHost? = nil) async {
        let engine: any EngineClient = host.flatMap { remotes[$0.id]?.engine } ?? engine
        do {
            try await engine.cloneRepo(url)
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forgets the repo. Its worktrees stay on disk.
    func removeRepo(_ repo: Repo) {
        let engine = engine(forRepo: repo.id)
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
            let workspace = try await engine(forRepo: repo.id).newWorkspace(in: repo.id)
            await sync()
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
            try await engine(for: workspace.id).rename(workspace.id, to: raw)
        } catch {
            return error.localizedDescription
        }
        await sync()
        await refreshBranch(workspace.id, network: false)
        return nil
    }

    /// This Mac's workspaces archived so far, from `archive.json`.
    func loadArchive() -> [Workspace] { storage.loadArchive() }

    /// Soft-deletes a workspace: the worktree goes, uncommitted work is saved
    /// to a ref, and the record moves to `archive.json`. The branch is kept.
    func archive(_ workspace: Workspace) async {
        do {
            try await engine(for: workspace.id).archive(workspace.id)
            await sync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Chat

    /// Sends one message. claude's turn streams into the transcript; a
    /// message sent while a turn is running waits for it to end.
    /// Returns false, with nothing sent, when the workspace's host is
    /// out of reach; the caller keeps the draft.
    @discardableResult
    func send(_ text: String, to id: UUID) -> Bool {
        guard reachable(id) else {
            errorMessage = "This workspace's host isn't connected, so the message wasn't sent."
            return false
        }
        let engine = engine(for: id)
        Task {
            if let remote = engine as? RemoteEngine {
                do {
                    try await remote.deliver(text, to: id)
                } catch {
                    errorMessage = "The message didn't reach the host: \(error.localizedDescription)"
                }
            } else {
                await engine.send(text, to: id)
            }
        }
        return true
    }

    func stop(_ id: UUID) {
        let engine = engine(for: id)
        Task { await engine.stop(id) }
    }

    // MARK: - Changes

    func refreshChanges(_ id: UUID) async {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        let files: [DiffFile]
        if let remote = engine(for: id) as? RemoteEngine {
            // A host that can't be asked keeps the list it last gave.
            guard let fetched = try? await remote.fetchChangedFiles(id) else { return }
            files = fetched
        } else {
            files = await engine.changedFiles(id)
        }
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
        try await engine(for: workspace.id).diff(of: file, in: workspace.id)
    }
}
