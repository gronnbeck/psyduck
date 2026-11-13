import Foundation

/// The workspace's pull request, from `gh pr view --json`.
struct PullRequest: Codable, Hashable {
    var number: Int
    var url: String
    /// OPEN, MERGED or CLOSED.
    var state: String
    var isDraft: Bool
}

/// Where a workspace's branch stands against its remote and its PR.
struct BranchState: Hashable {
    /// Uncommitted changes, staged or not, including untracked files.
    var dirty = false
    var hasRemote = false
    var hasUpstream = false
    /// Commits the upstream doesn't have.
    var ahead = 0
    /// Commits the upstream has that we don't.
    var behind = 0
    /// Commits on the branch since the workspace was cut.
    var commitsSinceBase = 0
    var pr: PullRequest?
}

/// The one thing the header button offers: the next step for this branch.
/// More will join later, so it is an enum the view switches on, not a bool.
enum PrimaryAction: Equatable {
    case pull
    case commit
    case commitAndPush
    case push
    case createPR
    case markReady(PullRequest)
    case viewPR(PullRequest)
    case merged(PullRequest)
    case none

    var title: String {
        switch self {
        case .pull: return "pull"
        case .commit: return "commit"
        case .commitAndPush: return "commit & push"
        case .push: return "push"
        case .createPR: return "create pr"
        case .markReady: return "ready for review"
        case .viewPR(let pr): return "view pr #\(pr.number)"
        case .merged(let pr): return "merged #\(pr.number)"
        case .none: return "no changes"
        }
    }

    var help: String {
        switch self {
        case .pull: return "the remote branch has commits you don't — pull them in (rebase, autostash)"
        case .commit: return "commit every change (no remote to push to)"
        case .commitAndPush: return "commit every change with a message claude writes, then push"
        case .push: return "push local commits"
        case .createPR: return "open a pull request, with a title and description claude writes"
        case .markReady: return "mark the draft pull request ready for review"
        case .viewPR: return "open the pull request in the browser"
        case .merged: return "the pull request is merged"
        case .none: return "nothing to commit, push or open yet"
        }
    }

    /// Picks the next step. Order matters: catch up with the remote before
    /// anything else, then get local work committed and pushed, then the PR.
    static func decide(_ state: BranchState) -> PrimaryAction {
        if let pr = state.pr, pr.state == "MERGED" { return .merged(pr) }
        if state.hasRemote && state.behind > 0 { return .pull }
        if state.dirty { return state.hasRemote ? .commitAndPush : .commit }
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
    func branchState(worktree: String, base: String, branch: String,
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
