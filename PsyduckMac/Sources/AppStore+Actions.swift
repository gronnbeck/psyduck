import AppKit
import Foundation

/// The header's primary action: commit, push, pull, open or ready a PR.
/// git and gh do the work directly, so it behaves the same whatever claude's
/// permission mode is. claude only writes text (commit message, PR title and
/// description), with every tool turned off.
extension AppStore {
    func primaryAction(for id: UUID) -> PrimaryAction {
        branches[id].map(PrimaryAction.decide) ?? .none
    }

    var ghPath: String? { try? Shell.resolve("gh", configured: "") }

    func refreshBranch(_ id: UUID, network: Bool) async {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let state = await settings.git.branchState(
            worktree: workspace.path, base: workspace.baseCommit, branch: workspace.branch,
            gh: ghPath, network: network, previousPR: branches[id]?.pr)
        branches[id] = state
    }

    func perform(_ action: PrimaryAction, on id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }), !acting.contains(id) else { return }

        switch action {
        case .viewPR(let pr), .merged(let pr):
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            return
        case .none:
            return
        default:
            break
        }

        acting.insert(id)
        Task {
            defer { acting.remove(id) }
            do {
                let note = try await run(action, in: workspace)
                appendNote(note, to: id)
            } catch {
                appendNote("\(action.title) failed: \(error.localizedDescription)", to: id, isError: true)
            }
            await refreshBranch(id, network: true)
            await refreshChanges(id)
        }
    }

    private func run(_ action: PrimaryAction, in workspace: Workspace) async throws -> String {
        let git = settings.git
        let dir = workspace.path
        switch action {
        case .pull:
            try await git.output(["pull", "--rebase", "--autostash", "origin", workspace.branch], in: dir)
            return "pulled \(workspace.branch)"

        case .commit, .commitAndPush:
            try await git.output(["add", "-A"], in: dir)
            let message = await commitMessage(for: workspace)
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
                try await git.output(["commit", "-m", await commitMessage(for: workspace)], in: dir)
            }
            try await git.output(["push", "-u", "origin", "HEAD"], in: dir)
            let (title, body) = await pullRequestText(for: workspace)
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

    /// The panel's "Commit" button: commit everything, don't push.
    func commitOnly(_ id: UUID) {
        perform(.commit, on: id)
    }

    /// Throws away every uncommitted change, untracked files included.
    /// The view confirms first.
    func discard(_ id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }), !acting.contains(id) else { return }
        acting.insert(id)
        Task {
            defer { acting.remove(id) }
            do {
                try await settings.git.output(["reset", "--hard", "HEAD"], in: workspace.path)
                try await settings.git.output(["clean", "-fd"], in: workspace.path)
                appendNote("discarded uncommitted changes", to: id)
            } catch {
                appendNote("discard failed: \(error.localizedDescription)", to: id, isError: true)
            }
            await refreshBranch(id, network: false)
            await refreshChanges(id)
        }
    }

    private func appendNote(_ text: String, to id: UUID, isError: Bool = false) {
        guard !text.isEmpty, let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].items.append(ChatItem(kind: isError ? .error : .meta, text: text))
        save()
    }

    // MARK: - Text claude writes

    /// What the user asked for in this workspace — the best hint at *why*.
    private func recentAsks(_ workspace: Workspace) -> String {
        workspace.items.filter { $0.kind == .user }.suffix(5).map { "- \($0.text.prefix(400))" }.joined(separator: "\n")
    }

    private func commitMessage(for workspace: Workspace) async -> String {
        let git = settings.git
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
        let text = await writeText(prompt, in: workspace.path)
        return text.isEmpty ? "chore: changes from \(workspace.name)" : text
    }

    private func pullRequestText(for workspace: Workspace) async -> (String, String) {
        let git = settings.git
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
        let text = await writeText(prompt, in: workspace.path)
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
    private func writeText(_ prompt: String, in directory: String) async -> String {
        guard let claude = try? settings.resolvedClaude() else { return "" }
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
