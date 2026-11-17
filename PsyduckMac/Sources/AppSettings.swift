import Foundation
import PsyduckCore

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
        ("bypassPermissions", "Bypass: Claude runs any tool without asking"),
        ("acceptEdits", "Accept edits: other tools only if your Claude settings allow them"),
        ("plan", "Plan: read only, no changes"),
    ]

    static var defaultWorkspacesRoot: String { EngineConfig.defaultWorkspacesRoot }
    static var defaultReposRoot: String { EngineConfig.defaultReposRoot }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        gitPath = defaults.string(forKey: "gitPath") ?? ""
        workspacesRoot = defaults.string(forKey: "workspacesRoot") ?? Self.defaultWorkspacesRoot
        reposRoot = defaults.string(forKey: "reposRoot") ?? Self.defaultReposRoot
        permissionMode = defaults.string(forKey: "permissionMode") ?? EngineConfig.defaultPermissionMode
        model = defaults.string(forKey: "model") ?? ""
    }

    /// The settings as the engine takes them.
    var config: EngineConfig {
        EngineConfig(claudePath: claudePath, gitPath: gitPath, workspacesRoot: workspacesRoot,
                     reposRoot: reposRoot, permissionMode: permissionMode, model: model)
    }

    func resolvedClaude() throws -> String { try config.resolvedClaude() }

    /// Fills in the claude path on first launch, so it shows in settings.
    func detectMissing() async {
        if claudePath.isEmpty, let found = await Shell.detect("claude") {
            claudePath = found
        }
    }
}
