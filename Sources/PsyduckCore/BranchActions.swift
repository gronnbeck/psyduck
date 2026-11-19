import Foundation

/// The workspace's pull request, from `gh pr view --json`.
public struct PullRequest: Codable, Hashable, Sendable {
    public var number: Int
    public var url: String
    /// OPEN, MERGED or CLOSED.
    public var state: String
    public var isDraft: Bool

    public init(number: Int, url: String, state: String, isDraft: Bool) {
        self.number = number
        self.url = url
        self.state = state
        self.isDraft = isDraft
    }
}

/// Where a workspace's branch stands against its remote and its PR.
public struct BranchState: Codable, Hashable, Sendable {
    /// Uncommitted changes, staged or not, including untracked files.
    public var dirty = false
    public var hasRemote = false
    public var hasUpstream = false
    /// Commits the upstream doesn't have.
    public var ahead = 0
    /// Commits the upstream has that we don't.
    public var behind = 0
    /// Commits on the branch since the workspace was cut.
    public var commitsSinceBase = 0
    public var pr: PullRequest?

    public init(dirty: Bool = false, hasRemote: Bool = false, hasUpstream: Bool = false, ahead: Int = 0,
                behind: Int = 0, commitsSinceBase: Int = 0, pr: PullRequest? = nil) {
        self.dirty = dirty
        self.hasRemote = hasRemote
        self.hasUpstream = hasUpstream
        self.ahead = ahead
        self.behind = behind
        self.commitsSinceBase = commitsSinceBase
        self.pr = pr
    }
}

/// The one thing the header button offers: the next step for this branch.
/// More will join later, so it is an enum the view switches on, not a bool.
public enum PrimaryAction: Equatable, Codable, Sendable {
    case pull
    case commit
    case commitAndPush
    case push
    case createPR
    case markReady(PullRequest)
    case viewPR(PullRequest)
    case merged(PullRequest)
    case none

    public var title: String {
        switch self {
        case .pull: return "Pull"
        case .commit: return "Commit"
        case .commitAndPush: return "Commit & push"
        case .push: return "Push"
        case .createPR: return "Create PR"
        case .markReady: return "Ready for review"
        case .viewPR(let pr): return "PR #\(pr.number)"
        case .merged(let pr): return "Merged #\(pr.number)"
        case .none: return "Create PR"
        }
    }

    public var help: String {
        switch self {
        case .pull: return "the remote branch has commits you don't — pull them in (rebase, autostash)"
        case .commit: return "commit every change (no remote to push to)"
        case .commitAndPush: return "commit every change with a message claude writes, then push"
        case .push: return "push local commits"
        case .createPR: return "commit anything outstanding, push, and open a pull request with a title and description claude writes"
        case .markReady: return "mark the draft pull request ready for review"
        case .viewPR: return "open the pull request in the browser"
        case .merged: return "the pull request is merged"
        case .none: return "nothing to open a PR with yet"
        }
    }

    /// Picks the next step. Order matters: catch up with the remote before
    /// anything else, then get local work committed and pushed, then the PR.
    public static func decide(_ state: BranchState) -> PrimaryAction {
        if let pr = state.pr, pr.state == "MERGED" { return .merged(pr) }
        if state.hasRemote && state.behind > 0 { return .pull }
        if state.dirty {
            guard state.hasRemote else { return .commit }
            // No PR yet: one press commits, pushes and opens it.
            if let pr = state.pr, pr.state == "OPEN" { return .commitAndPush }
            return .createPR
        }
        guard state.hasRemote else { return .none }
        if state.ahead > 0 || (!state.hasUpstream && state.commitsSinceBase > 0) { return .push }
        if let pr = state.pr, pr.state == "OPEN" {
            return pr.isDraft ? .markReady(pr) : .viewPR(pr)
        }
        if state.commitsSinceBase > 0 { return .createPR }
        return .none
    }
}

extension Git {
    /// Reads the branch's state. `network` also fetches the branch and asks
    /// GitHub about its PR — slower, so the caller does it less often.
    public func branchState(worktree: String, base: String, branch: String,
                     gh: String?, network: Bool, previousPR: PullRequest?) async -> BranchState {
        var state = BranchState()
        state.dirty = !((try? await output(["status", "--porcelain"], in: worktree)) ?? "").isEmpty
        state.hasRemote = (try? await output(["remote", "get-url", "origin"], in: worktree)) != nil
        state.commitsSinceBase = Int((try? await output(["rev-list", "--count", "\(base)..HEAD"], in: worktree)) ?? "") ?? 0

        if state.hasRemote && network {
            // Quietly: a branch that was never pushed has nothing to fetch.
            _ = try? await run(["fetch", "--quiet", "origin", branch], in: worktree)
        }
        if let counts = try? await output(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: worktree) {
            state.hasUpstream = true
            let parts = counts.split(whereSeparator: { $0 == "\t" || $0 == " " })
            state.ahead = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
            state.behind = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        }

        state.pr = previousPR
        if state.hasRemote && network, let gh {
            let result = try? await Shell.run(gh, ["pr", "view", branch, "--json", "number,url,state,isDraft"],
                                              directory: URL(fileURLWithPath: worktree))
            if let result, result.ok {
                state.pr = try? JSONDecoder().decode(PullRequest.self, from: Data(result.stdout.utf8))
            } else if let result, result.stderr.contains("no pull requests found") {
                state.pr = nil
            }
        }
        return state
    }
}

extension PrimaryAction {
    /// Actions that change files or history in the worktree — held back
    /// while Claude is editing it.
    public var touchesWorkTree: Bool {
        switch self {
        case .pull, .commit, .commitAndPush, .createPR: return true
        default: return false
        }
    }
}
