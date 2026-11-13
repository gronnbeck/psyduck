import Foundation
import SwiftUI

/// Saved to disk between launches.
private struct SavedState: Codable {
    var repos: [Repo]
    var workspaces: [Workspace]
}

/// Everything the window shows: repos, workspaces, the running chats and
/// each workspace's changed files.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []
    @Published var workspaces: [Workspace] = []
    @Published var selection: UUID?
    @Published var errorMessage: String?
    /// Settings is a page in the main window, over the chat and changes panes.
    @Published var showingSettings = false

    /// Workspaces with a claude turn in flight.
    @Published private(set) var running: Set<UUID> = []
    /// The reply being written right now, before claude finishes the block.
    @Published private(set) var streaming: [UUID: String] = [:]

    @Published private(set) var changes: [UUID: [DiffFile]] = [:]
    /// Each workspace's branch against its remote and PR, for the header button.
    @Published var branches: [UUID: BranchState] = [:]
    /// Workspaces with a header action (commit, push, PR…) in flight.
    @Published var acting: Set<UUID> = []
    /// The file opened wide in the center pane, per workspace.
    @Published var openDiff: [UUID: DiffFile] = [:]
    /// The file whose diff shows inline in the changes panel, per workspace.
    @Published var selectedFile: [UUID: DiffFile] = [:]

    let settings: AppSettings
    private let stateURL: URL?
    private var turns: [UUID: Task<Void, Never>] = [:]
    /// When the running turn started, for the composer's clock.
    @Published private(set) var turnStarted: [UUID: Date] = [:]
    /// A follow-up typed while claude was busy, sent when the turn ends.
    @Published var queued: [UUID: String] = [:]
    /// Turns that got as far as claude's result line.
    private var finished: Set<UUID> = []

    init(settings: AppSettings, stateURL: URL? = AppStore.defaultStateURL()) {
        self.settings = settings
        self.stateURL = stateURL
        load()
        selection = workspaces.first?.id
    }

    nonisolated static func defaultStateURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "lol.np.psyduck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    // MARK: - Lookup

    var selectedWorkspace: Workspace? { workspaces.first { $0.id == selection } }

    func repo(for workspace: Workspace) -> Repo? { repos.first { $0.id == workspace.repoID } }

    func workspaces(in repo: Repo) -> [Workspace] {
        workspaces.filter { $0.repoID == repo.id }.sorted { $0.createdAt > $1.createdAt }
    }

    private func index(of id: UUID) -> Int? { workspaces.firstIndex { $0.id == id } }

    // MARK: - Persistence

    private func load() {
        guard let stateURL, let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        repos = state.repos
        workspaces = state.workspaces
    }

    func save() {
        guard let stateURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(SavedState(repos: repos, workspaces: workspaces)) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: - Repos

    /// Adds a local repository. Any directory inside it works; the repo's
    /// top level is what's stored.
    func addRepo(at path: String) async {
        do {
            let top = try await settings.git.topLevel(of: path)
            if repos.contains(where: { $0.path == top }) { return }
            repos.append(Repo(name: (top as NSString).lastPathComponent, path: top))
            repos.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Clones `url` under the repos root, then adds it.
    func cloneRepo(_ url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = (trimmed as NSString).lastPathComponent
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !name.isEmpty else { errorMessage = "that doesn't look like a repo url"; return }
        let directory = (settings.expandedReposRoot as NSString).appendingPathComponent(name)
        do {
            if !FileManager.default.fileExists(atPath: directory) {
                try await settings.git.clone(trimmed, into: directory)
            }
            await addRepo(at: directory)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forgets the repo. Its worktrees stay on disk.
    func removeRepo(_ repo: Repo) {
        for workspace in workspaces where workspace.repoID == repo.id { stop(workspace.id) }
        workspaces.removeAll { $0.repoID == repo.id }
        repos.removeAll { $0.id == repo.id }
        if selectedWorkspace == nil { selection = workspaces.first?.id }
        save()
    }

    // MARK: - Workspaces

    @Published private(set) var creating: Set<UUID> = []

    /// Makes a new worktree on a fresh `psyduck/<name>` branch cut from the
    /// repo's default branch, and selects it.
    func newWorkspace(in repo: Repo) async {
        creating.insert(repo.id)
        defer { creating.remove(repo.id) }

        let git = settings.git
        let repoRoot = (settings.expandedWorkspacesRoot as NSString).appendingPathComponent(repo.name)
        var taken = Set(workspaces.filter { $0.repoID == repo.id }.map(\.name))
        var name = DuckNames.next(taken: taken)
        while true {
            let dirTaken = FileManager.default.fileExists(atPath: (repoRoot as NSString).appendingPathComponent(name))
            let branchTaken = await git.branchExists("psyduck/\(name)", repo: repo.path)
            if !dirTaken && !branchTaken { break }
            taken.insert(name)
            name = DuckNames.next(taken: taken)
        }

        let directory = (repoRoot as NSString).appendingPathComponent(name)
        let branch = "psyduck/\(name)"
        do {
            let baseRef = await git.defaultBaseRef(repo: repo.path)
            let commit = try await git.addWorktree(repo: repo.path, directory: directory, branch: branch, baseRef: baseRef)
            let workspace = Workspace(repoID: repo.id, name: name, branch: branch, path: directory,
                                      baseRef: baseRef, baseCommit: commit)
            workspaces.append(workspace)
            selection = workspace.id
            showingSettings = false
            save()
            await refreshChanges(workspace.id)
        } catch {
            errorMessage = "couldn't make a worktree: \(error.localizedDescription)"
        }
    }

    /// Soft-deletes a workspace: stops claude, saves any uncommitted work to
    /// a ref, removes the worktree and moves the record to `archive.json`,
    /// which isn't loaded at launch. The branch is kept.
    func archive(_ workspace: Workspace) async {
        stop(workspace.id)
        var archived = workspace
        archived.archivedAt = Date()
        if let repo = repo(for: workspace), FileManager.default.fileExists(atPath: workspace.path) {
            do {
                let git = settings.git
                archived.archivedWork = try await git.snapshotWork(
                    in: workspace.path, ref: "refs/psyduck/archive/\(workspace.id.uuidString)")
                try await git.removeWorktree(repo: repo.path, directory: workspace.path)
            } catch {
                errorMessage = "couldn't archive the workspace: \(error.localizedDescription)"
                return
            }
        }
        appendToArchive(archived)
        workspaces.removeAll { $0.id == workspace.id }
        let id = workspace.id
        changes[id] = nil
        branches[id] = nil
        openDiff[id] = nil
        selectedFile[id] = nil
        queued[id] = nil
        streaming[id] = nil
        if selection == workspace.id { selection = workspaces.first?.id }
        save()
    }

    /// Archived workspaces, next to `state.json`. Read and written only when
    /// archiving (and, later, restoring), so they cost nothing at runtime.
    var archiveURL: URL? { stateURL?.deletingLastPathComponent().appendingPathComponent("archive.json") }

    func loadArchive() -> [Workspace] {
        guard let archiveURL, let data = try? Data(contentsOf: archiveURL) else { return [] }
        return (try? JSONDecoder().decode([Workspace].self, from: data)) ?? []
    }

    private func appendToArchive(_ workspace: Workspace) {
        guard let archiveURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(loadArchive() + [workspace]) {
            try? data.write(to: archiveURL, options: .atomic)
        }
    }

    // MARK: - Chat

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    /// Sends one message and streams claude's turn into the transcript.
    /// claude runs in the workspace's worktree, resuming its last session.
    func send(_ text: String, to id: UUID) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let i = index(of: id) else { return }
        if running.contains(id) {
            // Busy: hold it until this turn ends.
            queued[id] = [queued[id], message].compactMap { $0 }.joined(separator: "\n\n")
            return
        }

        let claude: String
        do {
            claude = try settings.resolvedClaude()
        } catch {
            workspaces[i].items.append(ChatItem(kind: .error, text: error.localizedDescription))
            return
        }

        workspaces[i].items.append(ChatItem(kind: .user, text: message))
        let workspace = workspaces[i]
        running.insert(id)
        turnStarted[id] = Date()
        finished.remove(id)
        streaming[id] = ""
        save()

        let arguments = Self.claudeArguments(sessionID: workspace.claudeSessionID,
                                             permissionMode: settings.permissionMode,
                                             model: settings.model)
        turns[id] = Task { [weak self] in
            do {
                let result = try await Shell.stream(claude, arguments,
                                                    directory: URL(fileURLWithPath: workspace.path),
                                                    input: Data(message.utf8)) { line in
                    let events = ClaudeStream.parse(line)
                    guard !events.isEmpty else { return }
                    // Main queue rather than a Task: it's FIFO, so events land
                    // in the order claude wrote them.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            for event in events { self?.apply(event, to: id) }
                        }
                    }
                }
                await MainActor.run {} // let queued events land first
                if !result.ok, self?.finished.contains(id) == false, !Task.isCancelled {
                    self?.append(ChatItem(kind: .error, text: "claude exited with status \(result.status): \(result.failureLine)"), to: id)
                }
            } catch {
                self?.append(ChatItem(kind: .error, text: error.localizedDescription), to: id)
            }
            self?.finishTurn(id, cancelled: Task.isCancelled)
        }
    }

    nonisolated static func claudeArguments(sessionID: String?, permissionMode: String, model: String) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--permission-mode", permissionMode]
        if let sessionID { arguments += ["--resume", sessionID] }
        let model = model.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

    func stop(_ id: UUID) {
        turns[id]?.cancel()
    }

    private func append(_ item: ChatItem, to id: UUID) {
        guard let i = index(of: id) else { return }
        workspaces[i].items.append(item)
    }

    private func apply(_ event: ClaudeEvent, to id: UUID) {
        guard let i = index(of: id) else { return }
        switch event {
        case .started(let sessionID):
            workspaces[i].claudeSessionID = sessionID
        case .textDelta(let text):
            streaming[id, default: ""] += text
        case .text(let text):
            streaming[id] = ""
            workspaces[i].items.append(ChatItem(kind: .assistant, text: text))
        case .toolUse(let toolID, let name, let summary):
            streaming[id] = ""
            workspaces[i].items.append(ChatItem(kind: .tool, text: name, detail: summary, toolID: toolID))
        case .toolResult(let toolID, let isError, let output):
            guard let t = workspaces[i].items.lastIndex(where: { $0.kind == .tool && $0.toolID == toolID }) else { break }
            workspaces[i].items[t].isError = isError
            // Shell output becomes a terminal block; for other tools only a
            // failure is worth showing.
            if workspaces[i].items[t].isShell || isError {
                workspaces[i].items[t].output = output
            }
            // Edits land while claude works; keep the panel close behind.
            Task { await refreshChanges(id) }
        case .finished(let isError, let message, let durationMs, let cost, let sessionID):
            finished.insert(id)
            if let sessionID { workspaces[i].claudeSessionID = sessionID }
            if isError {
                workspaces[i].items.append(ChatItem(kind: .error, text: message ?? "claude reported an error"))
            }
            var parts: [String] = []
            if let durationMs { parts.append(String(format: "%.1fs", Double(durationMs) / 1000)) }
            if let cost {
                parts.append(String(format: "$%.3f", cost))
                workspaces[i].totalCost = (workspaces[i].totalCost ?? 0) + cost
            }
            if !parts.isEmpty {
                workspaces[i].items.append(ChatItem(kind: .meta, text: parts.joined(separator: " · ")))
            }
        }
    }

    private func finishTurn(_ id: UUID, cancelled: Bool) {
        if cancelled { append(ChatItem(kind: .meta, text: "stopped"), to: id) }
        if let partial = streaming[id], !partial.isEmpty {
            append(ChatItem(kind: .assistant, text: partial), to: id)
        }
        streaming[id] = nil
        running.remove(id)
        turnStarted[id] = nil
        turns[id] = nil
        save()
        Task { await refreshChanges(id) }
        // Stopping also drops the queue: the user is taking over.
        if let next = queued.removeValue(forKey: id), !cancelled {
            send(next, to: id)
        }
    }

    // MARK: - Changes

    func refreshChanges(_ id: UUID) async {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        do {
            let files = try await settings.git.changedFiles(in: workspace.path, base: workspace.baseCommit)
            changes[id] = files
            if let open = openDiff[id], !files.contains(where: { $0.path == open.path }) {
                openDiff[id] = nil
            }
        } catch {
            changes[id] = []
        }
    }
}
