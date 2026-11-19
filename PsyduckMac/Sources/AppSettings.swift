import Foundation
import PsyduckCore

/// A machine that runs agents for this app: `psyduck serve` on the other
/// end of `command`, which is run through the shell and spoken to over its
/// stdin and stdout. Usually ssh:
///   ssh studio docker exec -i psyduck psyduck attach
struct RemoteHost: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String

    /// What the sidebar calls it.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "remote host" : trimmed
    }

    /// Nothing to connect with until there's a command.
    var isUsable: Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

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
    /// Other machines that run agents for this app.
    @Published var hosts: [RemoteHost] {
        didSet { defaults.set(try? JSONEncoder().encode(hosts), forKey: "hosts") }
    }

    /// When a host's workspace is copied to this Mac: `off` (only when asked),
    /// `open` (the session you have open, as it changes) or `all`.
    @Published var mirrorMode: String { didSet { defaults.set(mirrorMode, forKey: "mirrorMode") } }
    /// Where the copies go: `<root>/<host>/<repo>/<workspace>`.
    @Published var mirrorsRoot: String { didSet { defaults.set(mirrorsRoot, forKey: "mirrorsRoot") } }

    static let mirrorModes: [(id: String, label: String)] = [
        ("off", "Only when I ask"),
        ("open", "The session I have open, whenever Claude changes something"),
        ("all", "Every session on a host, whenever Claude changes something"),
    ]
    static let defaultMirrorsRoot = "~/psyduck/mirrors"

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
        mirrorMode = defaults.string(forKey: "mirrorMode") ?? "off"
        mirrorsRoot = defaults.string(forKey: "mirrorsRoot") ?? Self.defaultMirrorsRoot
        hosts = defaults.data(forKey: "hosts").flatMap { try? JSONDecoder().decode([RemoteHost].self, from: $0) } ?? []
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
