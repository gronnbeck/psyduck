import Foundation

/// A git repository the user has added. Workspaces are worktrees of it.
struct Repo: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// The repository's top-level directory.
    var path: String
}

/// One isolated piece of work: a git worktree on its own branch, with one
/// claude session running inside it.
struct Workspace: Codable, Identifiable, Hashable {
    var id = UUID()
    var repoID: UUID
    /// Short, human name, also the last path component and the branch suffix.
    var name: String
    var branch: String
    /// The worktree's directory. claude runs here, never in the repo itself.
    var path: String
    /// What the branch was cut from, e.g. `main` or `origin/main`.
    var baseRef: String
    /// The exact commit `baseRef` pointed at when the workspace was made — the
    /// diff panel compares against this, so it shows only this workspace's work.
    var baseCommit: String
    /// claude's own session id, from the last turn. Passed back with
    /// `--resume` so the conversation continues.
    var claudeSessionID: String?
    var createdAt = Date()
    var items: [ChatItem] = []
}

/// One row in the chat transcript.
struct ChatItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case user
        case assistant
        /// A tool claude called: `text` is the tool name, `detail` its main argument.
        case tool
        /// The end-of-turn line: duration and cost.
        case meta
        case error
    }

    var id = UUID()
    var kind: Kind
    var text: String
    var detail: String?
    var isError = false
}

/// Names for new workspaces. Ducks, obviously.
enum DuckNames {
    static let all = [
        "mallard", "teal", "wigeon", "pintail", "eider", "scoter", "merganser",
        "gadwall", "shoveler", "canvasback", "redhead", "bufflehead", "goldeneye",
        "smew", "garganey", "mandarin", "muscovy", "pekin", "harlequin", "scaup",
        "pochard", "whistler", "shelduck", "steamer", "torrent", "baikal",
    ]

    /// The first name not in `taken`, adding a number once they've all been used.
    static func next(taken: Set<String>) -> String {
        if let free = all.shuffled().first(where: { !taken.contains($0) }) { return free }
        var n = 2
        while true {
            for name in all where !taken.contains("\(name)-\(n)") { return "\(name)-\(n)" }
            n += 1
        }
    }
}
