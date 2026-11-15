import Foundation

/// A git repository the user has added. Workspaces are worktrees of it.
public struct Repo: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    /// The repository's top-level directory.
    public var path: String

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// One isolated piece of work: a git worktree on its own branch, with one
/// claude session running inside it. Its chat lives in the workspace's event
/// log, not here.
public struct Workspace: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var repoID: UUID
    /// Short, human name, also the last path component and the branch suffix.
    public var name: String
    public var branch: String
    /// The worktree's directory. claude runs here, never in the repo itself.
    public var path: String
    /// What the branch was cut from, e.g. `main` or `origin/main`.
    public var baseRef: String
    /// The exact commit `baseRef` pointed at when the workspace was made — the
    /// diff panel compares against this, so it shows only this workspace's work.
    public var baseCommit: String
    /// claude's own session id, from the last turn. Passed back with
    /// `--resume` so the conversation continues.
    public var claudeSessionID: String?
    /// What every turn in this workspace has cost so far.
    public var totalCost: Double?
    public var createdAt = Date()

    public init(id: UUID = UUID(), repoID: UUID, name: String, branch: String, path: String,
                baseRef: String, baseCommit: String, claudeSessionID: String? = nil,
                totalCost: Double? = nil, createdAt: Date = Date()) {
        self.id = id
        self.repoID = repoID
        self.name = name
        self.branch = branch
        self.path = path
        self.baseRef = baseRef
        self.baseCommit = baseCommit
        self.claudeSessionID = claudeSessionID
        self.totalCost = totalCost
        self.createdAt = createdAt
    }
}

/// One row in the chat transcript. Built from a workspace's events by
/// `Transcript`; never stored on its own.
public struct ChatItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user
        case assistant
        /// A tool claude called: `text` is the tool name, `detail` its main argument.
        case tool
        /// The end-of-turn line: duration and cost.
        case meta
        case error
    }

    public var id = UUID()
    public var kind: Kind
    public var text: String
    public var detail: String?
    public var isError = false
    /// For `.tool`: claude's id for the call, to match its result.
    public var toolID: String?
    /// For `.tool`: what it returned (shell commands only), tail-trimmed.
    public var output: String?

    public init(id: UUID = UUID(), kind: Kind, text: String, detail: String? = nil,
                isError: Bool = false, toolID: String? = nil, output: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.isError = isError
        self.toolID = toolID
        self.output = output
    }

    public var isShell: Bool { kind == .tool && text == "Bash" }

    /// The file a tool touched, if it's a file tool.
    public var filePath: String? {
        guard kind == .tool, ["Edit", "Write", "MultiEdit", "Read", "NotebookEdit"].contains(text) else { return nil }
        return detail?.split(separator: "\n").first.map(String.init)
    }
}

/// Names for new workspaces. Ducks, obviously.
public enum DuckNames {
    public static let all = [
        "mallard", "teal", "wigeon", "pintail", "eider", "scoter", "merganser",
        "gadwall", "shoveler", "canvasback", "redhead", "bufflehead", "goldeneye",
        "smew", "garganey", "mandarin", "muscovy", "pekin", "harlequin", "scaup",
        "pochard", "whistler", "shelduck", "steamer", "torrent", "baikal",
    ]

    /// The first name not in `taken`, adding a number once they've all been used.
    public static func next(taken: Set<String>) -> String {
        if let free = all.shuffled().first(where: { !taken.contains($0) }) { return free }
        var n = 2
        while true {
            for name in all where !taken.contains("\(name)-\(n)") { return "\(name)-\(n)" }
            n += 1
        }
    }
}
