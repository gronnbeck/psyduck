import Foundation

/// User preferences, kept in UserDefaults (per bundle id, so edge and local
/// builds don't share them).
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    /// Path to the claude binary. Empty means "find it".
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: "claudePath") } }
    @Published var gitPath: String { didSet { defaults.set(gitPath, forKey: "gitPath") } }
    /// Where worktrees go: `<root>/<repo>/<workspace>`.
    @Published var workspacesRoot: String { didSet { defaults.set(workspacesRoot, forKey: "workspacesRoot") } }
    /// Where "clone from url" puts repos.
    @Published var reposRoot: String { didSet { defaults.set(reposRoot, forKey: "reposRoot") } }
    @Published var permissionMode: String { didSet { defaults.set(permissionMode, forKey: "permissionMode") } }
    /// Empty means claude's own default.
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }

    static let permissionModes: [(id: String, label: String)] = [
        ("bypassPermissions", "bypass — claude runs any tool without asking"),
        ("acceptEdits", "accept edits — other tools only if your claude settings allow them"),
        ("plan", "plan — read only, no changes"),
    ]

    static var defaultWorkspacesRoot: String { "~/psyduck/workspaces" }
    static var defaultReposRoot: String { "~/psyduck/repos" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        gitPath = defaults.string(forKey: "gitPath") ?? ""
        workspacesRoot = defaults.string(forKey: "workspacesRoot") ?? Self.defaultWorkspacesRoot
        reposRoot = defaults.string(forKey: "reposRoot") ?? Self.defaultReposRoot
        permissionMode = defaults.string(forKey: "permissionMode") ?? "bypassPermissions"
        model = defaults.string(forKey: "model") ?? ""
    }

    func resolvedClaude() throws -> String { try Shell.resolve("claude", configured: claudePath) }

    func resolvedGit() -> String {
        (try? Shell.resolve("git", configured: gitPath)) ?? "/usr/bin/git"
    }

    var git: Git { Git(gitPath: resolvedGit()) }

    var expandedWorkspacesRoot: String { (workspacesRoot as NSString).expandingTildeInPath }
    var expandedReposRoot: String { (reposRoot as NSString).expandingTildeInPath }

    /// Fills in the claude path on first launch, so it shows in settings.
    func detectMissing() async {
        if claudePath.isEmpty, let found = await Shell.detect("claude") {
            claudePath = found
        }
    }
}
