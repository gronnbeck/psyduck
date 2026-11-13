import Foundation

enum GitError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// A file that differs between a workspace and the commit it started from.
struct DiffFile: Identifiable, Hashable {
    enum Status: String {
        case added = "A", modified = "M", deleted = "D", untracked = "?", other = "~"
    }

    var path: String
    var status: Status
    /// Nil for binary files.
    var additions: Int?
    var deletions: Int?

    var id: String { path }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

/// One rendered line of a unified diff.
struct DiffLine: Identifiable, Hashable {
    enum Kind { case header, hunk, context, added, removed }

    var id: Int
    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
}

/// Every git operation psyduck does, run through the git CLI.
struct Git {
    var gitPath: String

    func run(_ arguments: [String], in directory: String) async throws -> CommandResult {
        try await Shell.run(gitPath, arguments, directory: URL(fileURLWithPath: directory))
    }

    /// Runs and returns trimmed stdout, or throws git's own complaint.
    @discardableResult
    func output(_ arguments: [String], in directory: String) async throws -> String {
        let result = try await run(arguments, in: directory)
        guard result.ok else { throw GitError.failed(result.failureLine) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Repos

    /// The top-level directory of the repo containing `path`.
    func topLevel(of path: String) async throws -> String {
        do {
            return try await output(["rev-parse", "--show-toplevel"], in: path)
        } catch {
            throw GitError.failed("\((path as NSString).lastPathComponent) isn't a git repository")
        }
    }

    func clone(_ url: String, into directory: String) async throws {
        let parent = (directory as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try await output(["clone", url, directory], in: parent)
    }

    /// The branch new workspaces start from: the remote's default branch,
    /// preferring the local copy of it when there is one, else whatever is
    /// checked out.
    func defaultBaseRef(repo: String) async -> String {
        if let remoteHead = try? await output(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo),
           !remoteHead.isEmpty {
            let local = remoteHead.replacingOccurrences(of: "origin/", with: "")
            if (try? await output(["rev-parse", "--verify", "--quiet", "refs/heads/\(local)"], in: repo)) != nil {
                return local
            }
            return remoteHead
        }
        for candidate in ["main", "master"] {
            if (try? await output(["rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"], in: repo)) != nil {
                return candidate
            }
        }
        return (try? await output(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)) ?? "HEAD"
    }

    func branchExists(_ branch: String, repo: String) async -> Bool {
        (try? await output(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo)) != nil
    }

    // MARK: - Worktrees

    /// Cuts `branch` from `baseRef` into a new worktree at `directory`, and
    /// returns the commit it started from.
    func addWorktree(repo: String, directory: String, branch: String, baseRef: String) async throws -> String {
        let commit = try await output(["rev-parse", "--verify", "\(baseRef)^{commit}"], in: repo)
        try FileManager.default.createDirectory(atPath: (directory as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try await output(["worktree", "add", "-b", branch, directory, commit], in: repo)
        return commit
    }

    /// Removes the worktree directory. The branch stays, so no work is lost.
    func removeWorktree(repo: String, directory: String) async throws {
        try await output(["worktree", "remove", "--force", directory], in: repo)
    }

    // MARK: - Diffs

    /// Everything that differs from `base`: commits on the branch, staged and
    /// unstaged changes, and untracked files.
    func changedFiles(in worktree: String, base: String) async throws -> [DiffFile] {
        let numstat = try await output(["diff", "--no-renames", "--numstat", base], in: worktree)
        let nameStatus = try await output(["diff", "--no-renames", "--name-status", base], in: worktree)
        let untracked = try await output(["ls-files", "--others", "--exclude-standard"], in: worktree)
        return Self.parseChangedFiles(numstat: numstat, nameStatus: nameStatus, untracked: untracked)
    }

    static func parseChangedFiles(numstat: String, nameStatus: String, untracked: String) -> [DiffFile] {
        var statuses: [String: DiffFile.Status] = [:]
        for line in nameStatus.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            statuses[String(parts[1])] = DiffFile.Status(rawValue: String(parts[0].prefix(1))) ?? .other
        }

        var files: [DiffFile] = []
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let path = String(parts[2])
            files.append(DiffFile(path: path, status: statuses[path] ?? .modified,
                                  additions: Int(parts[0]), deletions: Int(parts[1])))
        }
        for line in untracked.split(separator: "\n") where !line.isEmpty {
            files.append(DiffFile(path: String(line), status: .untracked, additions: nil, deletions: nil))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The unified diff for one file against `base`. Untracked files are
    /// diffed against nothing, so they read as all-new.
    func diff(of file: DiffFile, in worktree: String, base: String) async throws -> String {
        let arguments: [String]
        if file.status == .untracked {
            arguments = ["diff", "--no-index", "--", "/dev/null", file.path]
        } else {
            arguments = ["diff", "--no-renames", base, "--", file.path]
        }
        // `--no-index` exits 1 when the files differ, which they always do.
        let result = try await run(arguments, in: worktree)
        guard result.status <= 1 else { throw GitError.failed(result.failureLine) }
        return result.stdout
    }

    static func parseDiff(_ text: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var old = 0
        var new = 0
        var inHunk = false

        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = String(raw)
            if line.hasPrefix("@@") {
                inHunk = true
                // @@ -12,5 +12,7 @@ context
                let scanner = line.split(separator: " ")
                if scanner.count >= 3 {
                    old = Int(scanner[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(scanner[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                lines.append(DiffLine(id: index, kind: .hunk, text: line))
            } else if !inHunk || line.hasPrefix("diff --git") {
                inHunk = false
                if !line.isEmpty { lines.append(DiffLine(id: index, kind: .header, text: line)) }
            } else if line.hasPrefix("+") {
                lines.append(DiffLine(id: index, kind: .added, text: String(line.dropFirst()), newNumber: new))
                new += 1
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(id: index, kind: .removed, text: String(line.dropFirst()), oldNumber: old))
                old += 1
            } else if line.hasPrefix("\\") {
                lines.append(DiffLine(id: index, kind: .header, text: line))
            } else if line.hasPrefix(" ") {
                lines.append(DiffLine(id: index, kind: .context, text: String(line.dropFirst()),
                                      oldNumber: old, newNumber: new))
                old += 1
                new += 1
            }
        }
        return lines
    }
}
