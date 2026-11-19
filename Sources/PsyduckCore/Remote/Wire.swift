import Foundation

// What goes over a connection between a client and `psyduck serve`: one JSON
// object per line, both ways.
//
//   → {"id":1,"method":"snapshot"}
//   ← {"id":1,"result":{"repos":[…],"workspaces":[…]}}
//   → {"id":2,"method":"events","params":{"workspace":"…","since":12,"sub":7}}
//   ← {"id":2,"result":{}}
//   ← {"sub":7,"event":{"seq":13,"type":"text",…}}      (as they happen)
//   ← {"sub":7,"ended":true}                            (the workspace is gone)
//   ← {"id":3,"error":"that workspace doesn't exist"}

public enum Wire {
    /// Bumped when a client and server of different versions can't talk.
    public static let version = 1
    /// What `hello` lists under `capabilities`.
    public static let capabilities = ["files"]

    public enum Method: String, Codable, Sendable {
        case hello, snapshot, events, unsubscribe
        case addRepo, cloneRepo, removeRepo
        case newWorkspace, rename, archive
        case send, stop
        case changedFiles, diff, branchState, perform, discard
        case files, readFiles
    }

    /// Every call's arguments in one bag; each method reads what it needs.
    public struct Params: Codable, Sendable {
        public var repo: UUID?
        public var workspace: UUID?
        public var path: String?
        public var url: String?
        public var text: String?
        public var name: String?
        public var since: Int?
        /// The client's own number for an event subscription.
        public var sub: Int?
        public var network: Bool?
        public var file: DiffFile?
        public var action: PrimaryAction?
        public var paths: [String]?

        public init(repo: UUID? = nil, workspace: UUID? = nil, path: String? = nil, url: String? = nil,
                    text: String? = nil, name: String? = nil, since: Int? = nil, sub: Int? = nil,
                    network: Bool? = nil, file: DiffFile? = nil, action: PrimaryAction? = nil,
                    paths: [String]? = nil) {
            self.repo = repo
            self.workspace = workspace
            self.path = path
            self.url = url
            self.text = text
            self.name = name
            self.since = since
            self.sub = sub
            self.network = network
            self.file = file
            self.action = action
            self.paths = paths
        }
    }

    public struct Request: Codable, Sendable {
        public var id: Int
        public var method: Method
        public var params: Params?

        public init(id: Int, method: Method, params: Params? = nil) {
            self.id = id
            self.method = method
            self.params = params
        }
    }

    /// Every call's answer in one bag.
    public struct Result: Codable, Sendable {
        public var repos: [Repo]?
        public var workspaces: [Workspace]?
        public var repo: Repo?
        public var workspace: Workspace?
        public var files: [DiffFile]?
        public var diff: String?
        public var branch: BranchState?
        /// `hello`: the wire version and the machine's name.
        public var version: Int?
        public var host: String?
        /// `hello`: what this server can do beyond version 1's calls, so a
        /// newer app can tell an older host apart without refusing it.
        public var capabilities: [String]?
        public var entries: [FileEntry]?
        public var contents: [FileContent]?

        public init(repos: [Repo]? = nil, workspaces: [Workspace]? = nil, repo: Repo? = nil,
                    workspace: Workspace? = nil, files: [DiffFile]? = nil, diff: String? = nil,
                    branch: BranchState? = nil, version: Int? = nil, host: String? = nil,
                    capabilities: [String]? = nil, entries: [FileEntry]? = nil, contents: [FileContent]? = nil) {
            self.repos = repos
            self.workspaces = workspaces
            self.repo = repo
            self.workspace = workspace
            self.files = files
            self.diff = diff
            self.branch = branch
            self.version = version
            self.host = host
            self.capabilities = capabilities
            self.entries = entries
            self.contents = contents
        }
    }

    /// Anything the server sends: an answer (`id`), or an event (`sub`).
    public struct Message: Codable, Sendable {
        public var id: Int?
        public var result: Result?
        public var error: String?
        public var sub: Int?
        public var event: WorkspaceEvent?
        public var ended: Bool?

        public init(id: Int? = nil, result: Result? = nil, error: String? = nil,
                    sub: Int? = nil, event: WorkspaceEvent? = nil, ended: Bool? = nil) {
            self.id = id
            self.result = result
            self.error = error
            self.sub = sub
            self.event = event
            self.ended = ended
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
