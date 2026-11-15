import Foundation

public enum EngineError: LocalizedError {
    case unknownRepo
    case unknownWorkspace
    case badRepoURL
    case worktree(String)

    public var errorDescription: String? {
        switch self {
        case .unknownRepo: return "that repo isn't in psyduck"
        case .unknownWorkspace: return "that workspace doesn't exist"
        case .badRepoURL: return "that doesn't look like a repo url"
        case .worktree(let message): return message
        }
    }
}

/// Repos and workspaces, as a client sees them.
public struct EngineSnapshot: Sendable {
    public var repos: [Repo]
    public var workspaces: [Workspace]
}

/// Everything psyduck does that isn't drawing: repos, worktrees, the claude
/// turns and each workspace's event log. The Mac app runs one in-process; a
/// server runs one for remote clients. Turns keep going whether or not
/// anything is listening.
public actor WorkspaceEngine {
    public typealias ConfigProvider = @Sendable () async -> EngineConfig

    private let storage: EngineStorage
    private let config: ConfigProvider

    private var repos: [Repo]
    private var workspaces: [Workspace]
    private var logs: [UUID: EventLog] = [:]
    private var transcripts: [UUID: Transcript] = [:]

    private var turns: [UUID: Task<Void, Never>] = [:]
    private var subscribers: [UUID: [UUID: AsyncStream<WorkspaceEvent>.Continuation]] = [:]
    /// Workspaces with a branch action (commit, push, PR…) in flight.
    private var acting: Set<UUID> = []
    /// The last PR GitHub reported per workspace, kept between network checks.
    private var pullRequests: [UUID: PullRequest] = [:]

    /// `config` is asked at the start of each operation, so a changed setting
    /// applies from the next turn.
    public init(loaded: EngineStorage.Loaded = .init(), storage: EngineStorage = .init(stateURL: nil),
                config: @escaping ConfigProvider) {
        self.storage = storage
        self.config = config
        repos = loaded.repos
        workspaces = loaded.workspaces
        for workspace in loaded.workspaces {
            let events = loaded.events[workspace.id] ?? []
            logs[workspace.id] = EventLog(events: events, url: storage.logURL(for: workspace.id))
            transcripts[workspace.id] = Transcript(events: events)
        }
    }

    // MARK: - Lookup

    public func snapshot() -> EngineSnapshot {
        EngineSnapshot(repos: repos, workspaces: workspaces)
    }

    public func workspace(_ id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    public func transcript(for id: UUID) -> Transcript {
        transcripts[id] ?? Transcript()
    }

    public func isRunning(_ id: UUID) -> Bool { turns[id] != nil }

    private func index(of id: UUID) -> Int? { workspaces.firstIndex { $0.id == id } }

    private func save() {
        storage.save(repos: repos, workspaces: workspaces)
    }

    // MARK: - Repos

    /// Adds a local repository. Any directory inside it works; the repo's
    /// top level is what's stored. Adding one twice returns the first.
    @discardableResult
    public func addRepo(at path: String) async throws -> Repo {
        let top = try await config().git.topLevel(of: path)
        if let existing = repos.first(where: { $0.path == top }) { return existing }
        let repo = Repo(name: (top as NSString).lastPathComponent, path: top)
        repos.append(repo)
        repos.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
        return repo
    }

    /// Clones `url` under the repos root, then adds it.
    @discardableResult
    public func cloneRepo(_ url: String) async throws -> Repo {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = (trimmed as NSString).lastPathComponent
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !name.isEmpty else { throw EngineError.badRepoURL }
        let config = await config()
        let directory = (config.expandedReposRoot as NSString).appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: directory) {
            try await config.git.clone(trimmed, into: directory)
        }
        return try await addRepo(at: directory)
    }

    /// Forgets the repo and its workspaces. Their worktrees stay on disk.
    public func removeRepo(_ id: UUID) {
        for workspace in workspaces where workspace.repoID == id {
            stop(workspace.id)
            forget(workspace.id)
        }
        workspaces.removeAll { $0.repoID == id }
        repos.removeAll { $0.id == id }
        save()
    }

    // MARK: - Workspaces

    /// Makes a new worktree on a fresh `psyduck/<name>` branch cut from the
    /// repo's default branch. With `prompt`, its first turn starts right away.
    @discardableResult
    public func newWorkspace(in repoID: UUID, prompt: String? = nil) async throws -> Workspace {
        guard let repo = repos.first(where: { $0.id == repoID }) else { throw EngineError.unknownRepo }
        let config = await config()
        let git = config.git
        let repoRoot = (config.expandedWorkspacesRoot as NSString).appendingPathComponent(repo.name)

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
        let baseRef = await git.defaultBaseRef(repo: repo.path)
        let commit: String
        do {
            commit = try await git.addWorktree(repo: repo.path, directory: directory, branch: branch, baseRef: baseRef)
        } catch {
            throw EngineError.worktree("couldn't make a worktree: \(error.localizedDescription)")
        }
        let workspace = Workspace(repoID: repo.id, name: name, branch: branch, path: directory,
                                  baseRef: baseRef, baseCommit: commit)
        workspaces.append(workspace)
        logs[workspace.id] = EventLog(url: storage.logURL(for: workspace.id))
        transcripts[workspace.id] = Transcript()
        save()
        if let prompt { await send(prompt, to: workspace.id) }
        return workspace
    }

    /// Removes the worktree and forgets the workspace. The branch is kept.
    public func archive(_ id: UUID) async throws {
        guard let workspace = workspace(id) else { return }
        stop(id)
        if let repo = repos.first(where: { $0.id == workspace.repoID }),
           FileManager.default.fileExists(atPath: workspace.path) {
            do {
                try await config().git.removeWorktree(repo: repo.path, directory: workspace.path)
            } catch {
                throw EngineError.worktree("couldn't remove the worktree: \(error.localizedDescription)")
            }
        }
        workspaces.removeAll { $0.id == id }
        forget(id)
        save()
    }

    /// Drops everything kept for a workspace that's going away.
    private func forget(_ id: UUID) {
        for continuation in (subscribers[id] ?? [:]).values { continuation.finish() }
        subscribers[id] = nil
        logs[id] = nil
        transcripts[id] = nil
        pullRequests[id] = nil
        storage.deleteLog(for: id)
    }

    // MARK: - Events

    /// The workspace's events after `since`, then every new one as it
    /// happens. The stream ends when the workspace is archived or the caller
    /// stops listening.
    public func events(for id: UUID, since: Int = 0) -> AsyncStream<WorkspaceEvent> {
        let (stream, continuation) = AsyncStream<WorkspaceEvent>.makeStream()
        guard let log = logs[id] else {
            continuation.finish()
            return stream
        }
        for event in log.since(since) { continuation.yield(event) }
        if let transcript = transcripts[id], transcript.running, !transcript.streaming.isEmpty {
            continuation.yield(WorkspaceEvent(seq: log.lastSeq, kind: .partial(transcript.streaming)))
        }
        let token = UUID()
        subscribers[id, default: [:]][token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(token, from: id) }
        }
        return stream
    }

    private func unsubscribe(_ token: UUID, from id: UUID) {
        subscribers[id]?[token] = nil
    }

    /// Records an event and hands it to everyone listening.
    @discardableResult
    private func emit(_ kind: WorkspaceEvent.Kind, to id: UUID) -> WorkspaceEvent? {
        guard logs[id] != nil else { return nil }
        let event: WorkspaceEvent
        if kind.isLiveOnly {
            event = WorkspaceEvent(seq: logs[id]?.lastSeq ?? 0, kind: kind)
        } else {
            event = logs[id]!.append(kind)
        }
        transcripts[id, default: Transcript()].apply(event)
        for continuation in (subscribers[id] ?? [:]).values { continuation.yield(event) }
        return event
    }

    // MARK: - Chat

    /// Sends one message and runs claude's turn in the workspace's worktree,
    /// resuming its last session. If a turn is already running, the message
    /// waits and is sent when that turn ends. Returns once the turn has
    /// started, not when it's done.
    public func send(_ text: String, to id: UUID) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let config = await config()
        guard let workspace = workspace(id) else { return }

        if turns[id] != nil {
            // Busy: hold it until this turn ends.
            let waiting = [transcripts[id]?.queued, message].compactMap { $0 }.joined(separator: "\n\n")
            emit(.queued(waiting), to: id)
            return
        }

        let claude: String
        do {
            claude = try config.resolvedClaude()
        } catch {
            emit(.note(error.localizedDescription, isError: true), to: id)
            return
        }

        emit(.prompt(message), to: id)
        let arguments = ClaudeStream.arguments(sessionID: workspace.claudeSessionID,
                                               permissionMode: config.permissionMode, model: config.model)
        turns[id] = Task {
            await self.runTurn(id, claude: claude, arguments: arguments, directory: workspace.path, message: message)
        }
    }

    /// Stops the running turn, and drops anything queued behind it.
    public func stop(_ id: UUID) {
        turns[id]?.cancel()
    }

    private func runTurn(_ id: UUID, claude: String, arguments: [String], directory: String, message: String) async {
        // The pipe's handler yields lines in the order claude wrote them; the
        // loop below takes them one at a time, so events keep that order.
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        async let outcome = Self.runClaude(claude, arguments, directory: directory, message: message, into: continuation)

        var sawResult = false
        for await line in lines {
            for event in ClaudeStream.parse(line) {
                if case .finished = event { sawResult = true }
                apply(event, to: id)
            }
        }

        let result = await outcome
        let cancelled = Task.isCancelled
        switch result {
        case .success(let result):
            if !result.ok, !sawResult, !cancelled {
                emit(.note("claude exited with status \(result.status): \(result.failureLine)", isError: true), to: id)
            }
        case .failure(let error):
            emit(.note(error.localizedDescription, isError: true), to: id)
        }
        finishTurn(id, cancelled: cancelled)
    }

    private nonisolated static func runClaude(_ claude: String, _ arguments: [String], directory: String, message: String,
                                              into continuation: AsyncStream<Data>.Continuation) async -> Result<CommandResult, Error> {
        defer { continuation.finish() }
        do {
            return .success(try await Shell.stream(claude, arguments, directory: URL(fileURLWithPath: directory),
                                                   input: Data(message.utf8)) { continuation.yield($0) })
        } catch {
            return .failure(error)
        }
    }

    private func apply(_ event: ClaudeEvent, to id: UUID) {
        guard let i = index(of: id) else { return }
        switch event {
        case .started(let sessionID):
            workspaces[i].claudeSessionID = sessionID
            emit(.sessionStarted(sessionID), to: id)
        case .textDelta(let text):
            emit(.textDelta(text), to: id)
        case .text(let text):
            emit(.text(text), to: id)
        case .toolUse(let toolID, let name, let summary):
            emit(.toolUse(id: toolID, name: name, summary: summary), to: id)
        case .toolResult(let toolID, let isError, let output):
            emit(.toolResult(id: toolID, isError: isError, output: output), to: id)
        case .finished(let isError, let message, let durationMs, let cost, let sessionID):
            if let sessionID { workspaces[i].claudeSessionID = sessionID }
            if let cost { workspaces[i].totalCost = (workspaces[i].totalCost ?? 0) + cost }
            emit(.turnResult(isError: isError, message: message, durationMs: durationMs,
                             costUSD: cost, sessionID: sessionID), to: id)
        }
    }

    private func finishTurn(_ id: UUID, cancelled: Bool) {
        let partial = transcripts[id]?.streaming ?? ""
        turns[id] = nil
        emit(.turnEnded(cancelled: cancelled, partial: partial.isEmpty ? nil : partial), to: id)
        save()
        if !cancelled, let next = transcripts[id]?.queued {
            Task { await self.send(next, to: id) }
        }
    }

    // MARK: - Changes

    /// Every file the workspace changed since its base commit.
    public func changedFiles(_ id: UUID) async -> [DiffFile] {
        guard let workspace = workspace(id) else { return [] }
        return (try? await config().git.changedFiles(in: workspace.path, base: workspace.baseCommit)) ?? []
    }

    /// One file's unified diff against the workspace's base commit.
    public func diff(of file: DiffFile, in id: UUID) async throws -> String {
        guard let workspace = workspace(id) else { throw EngineError.unknownWorkspace }
        return try await config().git.diff(of: file, in: workspace.path, base: workspace.baseCommit)
    }

    // MARK: - Branch actions

    private var ghPath: String? { try? Shell.resolve("gh", configured: "") }

    /// Where the branch stands. `network` also fetches it and asks GitHub
    /// about its PR — slower, so callers do it less often.
    public func branchState(_ id: UUID, network: Bool) async -> BranchState? {
        guard let workspace = workspace(id) else { return nil }
        let state = await config().git.branchState(
            worktree: workspace.path, base: workspace.baseCommit, branch: workspace.branch,
            gh: ghPath, network: network, previousPR: pullRequests[id])
        if self.workspace(id) != nil { pullRequests[id] = state.pr }
        return state
    }

    /// Runs a branch action: commit, push, pull, open or ready a PR. git and
    /// gh do the work directly, so it behaves the same whatever claude's
    /// permission mode is. claude only writes text (the commit message, the
    /// PR title and description), with every tool turned off. The outcome
    /// lands in the chat as a note. Does nothing if one is already running.
    public func perform(_ action: PrimaryAction, on id: UUID) async {
        switch action {
        case .viewPR, .merged, .none: return
        default: break
        }
        guard let workspace = workspace(id), !acting.contains(id) else { return }
        acting.insert(id)
        defer { acting.remove(id) }
        do {
            let note = try await run(action, in: workspace)
            if !note.isEmpty { emit(.note(note, isError: false), to: id) }
        } catch {
            emit(.note("\(action.title) failed: \(error.localizedDescription)", isError: true), to: id)
        }
    }

    /// Throws away every uncommitted change, untracked files included.
    public func discard(_ id: UUID) async {
        guard let workspace = workspace(id), !acting.contains(id) else { return }
        acting.insert(id)
        defer { acting.remove(id) }
        let git = await config().git
        do {
            try await git.output(["reset", "--hard", "HEAD"], in: workspace.path)
            try await git.output(["clean", "-fd"], in: workspace.path)
            emit(.note("discarded uncommitted changes", isError: false), to: id)
        } catch {
            emit(.note("discard failed: \(error.localizedDescription)", isError: true), to: id)
        }
    }

    private func run(_ action: PrimaryAction, in workspace: Workspace) async throws -> String {
        let config = await config()
        let git = config.git
        let dir = workspace.path
        switch action {
        case .pull:
            try await git.output(["pull", "--rebase", "--autostash", "origin", workspace.branch], in: dir)
            return "pulled \(workspace.branch)"

        case .commit, .commitAndPush:
            try await git.output(["add", "-A"], in: dir)
            let message = await commitMessage(for: workspace, config: config)
            try await git.output(["commit", "-m", message], in: dir)
            let sha = try await git.output(["rev-parse", "--short", "HEAD"], in: dir)
            let subject = message.split(separator: "\n").first.map(String.init) ?? message
            guard action == .commitAndPush else { return "committed \(sha) — \(subject)" }
            try await git.output(["push", "-u", "origin", "HEAD"], in: dir)
            return "committed \(sha) — \(subject) · pushed"

        case .push:
            try await git.output(["push", "-u", "origin", "HEAD"], in: dir)
            return "pushed \(workspace.branch)"

        case .createPR:
            guard let gh = ghPath else { throw ShellError.notFound("gh") }
            // Pressed with work outstanding: commit and push it first.
            if !((try? await git.output(["status", "--porcelain"], in: dir)) ?? "").isEmpty {
                try await git.output(["add", "-A"], in: dir)
                try await git.output(["commit", "-m", await commitMessage(for: workspace, config: config)], in: dir)
            }
            try await git.output(["push", "-u", "origin", "HEAD"], in: dir)
            let (title, body) = await pullRequestText(for: workspace, config: config)
            let base = workspace.baseRef.hasPrefix("origin/") ? String(workspace.baseRef.dropFirst(7)) : workspace.baseRef
            let result = try await Shell.run(gh, ["pr", "create", "--base", base, "--head", workspace.branch,
                                                  "--title", title, "--body", body],
                                             directory: URL(fileURLWithPath: dir))
            guard result.ok else { throw GitError.failed(result.failureLine) }
            let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? ""
            return "opened pr — \(title) \(url)"

        case .markReady(let pr):
            guard let gh = ghPath else { throw ShellError.notFound("gh") }
            let result = try await Shell.run(gh, ["pr", "ready", String(pr.number)], directory: URL(fileURLWithPath: dir))
            guard result.ok else { throw GitError.failed(result.failureLine) }
            return "pr #\(pr.number) is ready for review"

        case .viewPR, .merged, .none:
            return ""
        }
    }

    // MARK: - Text claude writes

    /// What the user asked for in this workspace — the best hint at *why*.
    private func recentAsks(_ workspace: Workspace) -> String {
        (transcripts[workspace.id]?.items ?? []).filter { $0.kind == .user }.suffix(5)
            .map { "- \($0.text.prefix(400))" }.joined(separator: "\n")
    }

    private func commitMessage(for workspace: Workspace, config: EngineConfig) async -> String {
        let git = config.git
        let stat = (try? await git.output(["diff", "--cached", "--stat"], in: workspace.path)) ?? ""
        let diff = (try? await git.output(["diff", "--cached"], in: workspace.path)) ?? ""
        let prompt = """
        Write a git commit message for the staged changes below. Conventional-commit style \
        (feat:, fix:, chore:, …), imperative, first line under 72 characters, then optionally a \
        blank line and a short body. Output only the commit message — no quotes, no code fences.

        What the user asked for in this session:
        \(recentAsks(workspace))

        \(stat)

        \(diff.prefix(40_000))
        """
        let text = await Self.writeText(prompt, in: workspace.path, config: config)
        return text.isEmpty ? "chore: changes from \(workspace.name)" : text
    }

    private func pullRequestText(for workspace: Workspace, config: EngineConfig) async -> (String, String) {
        let git = config.git
        let log = (try? await git.output(["log", "--format=%s%n%b", "\(workspace.baseCommit)..HEAD"], in: workspace.path)) ?? ""
        let diff = (try? await git.output(["diff", "\(workspace.baseCommit)...HEAD"], in: workspace.path)) ?? ""
        let prompt = """
        Write a GitHub pull request for this branch. Output the title on the first line \
        (under 72 characters, no prefix like "Title:"), then a blank line, then a concise markdown \
        description: what changed and why, and how to test it if that's obvious. Output nothing else.

        What the user asked for in this session:
        \(recentAsks(workspace))

        Commits:
        \(log)

        Diff:
        \(diff.prefix(60_000))
        """
        let text = await Self.writeText(prompt, in: workspace.path, config: config)
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = lines.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if title.isEmpty {
            let first = log.split(separator: "\n").first.map(String.init) ?? workspace.branch
            return (first, "From psyduck workspace `\(workspace.name)`.")
        }
        return (title, body)
    }

    /// One tool-less claude call that returns plain text, or "" on failure.
    private static func writeText(_ prompt: String, in directory: String, config: EngineConfig) async -> String {
        guard let claude = try? config.resolvedClaude() else { return "" }
        let arguments = ["-p", "--model", "haiku", "--tools", "", "--no-session-persistence",
                         "--output-format", "text"]
        guard let result = try? await Shell.run(claude, arguments, directory: URL(fileURLWithPath: directory),
                                                input: Data(prompt.utf8)), result.ok else { return "" }
        var text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n").dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        return text
    }
}
