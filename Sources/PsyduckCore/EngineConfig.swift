import Foundation

/// What the engine needs to know to run git and claude. The Mac app fills it
/// from its settings page; a server reads it from a config file.
public struct EngineConfig: Codable, Equatable, Sendable {
    /// Path to the claude binary. Empty means "find it".
    public var claudePath: String
    public var gitPath: String
    /// Where worktrees go: `<root>/<repo>/<workspace>`.
    public var workspacesRoot: String
    /// Where "clone from url" puts repos.
    public var reposRoot: String
    public var permissionMode: String
    /// Empty means claude's own default.
    public var model: String

    public static let defaultWorkspacesRoot = "~/psyduck/workspaces"
    public static let defaultReposRoot = "~/psyduck/repos"
    public static let defaultPermissionMode = "bypassPermissions"

    public init(claudePath: String = "", gitPath: String = "",
                workspacesRoot: String = EngineConfig.defaultWorkspacesRoot,
                reposRoot: String = EngineConfig.defaultReposRoot,
                permissionMode: String = EngineConfig.defaultPermissionMode,
                model: String = "") {
        self.claudePath = claudePath
        self.gitPath = gitPath
        self.workspacesRoot = workspacesRoot
        self.reposRoot = reposRoot
        self.permissionMode = permissionMode
        self.model = model
    }

    /// Reads a config file: a JSON object with any of this struct's fields.
    /// What's missing, or a file that's missing or broken, gets the default.
    public static func load(from url: URL) -> EngineConfig {
        var config = EngineConfig()
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return config }
        if let value = values["claudePath"] { config.claudePath = value }
        if let value = values["gitPath"] { config.gitPath = value }
        if let value = values["workspacesRoot"] { config.workspacesRoot = value }
        if let value = values["reposRoot"] { config.reposRoot = value }
        if let value = values["permissionMode"] { config.permissionMode = value }
        if let value = values["model"] { config.model = value }
        return config
    }

    public func resolvedClaude() throws -> String { try Shell.resolve("claude", configured: claudePath) }

    public func resolvedGit() -> String {
        (try? Shell.resolve("git", configured: gitPath)) ?? "/usr/bin/git"
    }

    public var git: Git { Git(gitPath: resolvedGit()) }

    public var expandedWorkspacesRoot: String { (workspacesRoot as NSString).expandingTildeInPath }
    public var expandedReposRoot: String { (reposRoot as NSString).expandingTildeInPath }
}
