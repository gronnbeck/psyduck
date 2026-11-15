import PsyduckCore
import XCTest
@testable import Psyduck

/// The store on top of a real engine and real git. The engine itself is
/// tested in the package (`swift test` at the repo root).
final class AppStoreTests: XCTestCase {
    private var root: URL!
    private let git = Git(gitPath: "/usr/bin/git")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("psyduck-tests-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "t"]] {
            try await git.output(args, in: repo)
        }
        try "one\ntwo\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try await git.output(["add", "."], in: repo)
        try await git.output(["commit", "-m", "init"], in: repo)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testStoreCreatesWorkspaceInWorktree() async throws {
        let repo = root.appendingPathComponent("repo").path
        let defaults = UserDefaults(suiteName: "psyduck-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.gitPath = "/usr/bin/git"
        settings.workspacesRoot = root.appendingPathComponent("workspaces").path
        let store = AppStore(settings: settings, stateURL: root.appendingPathComponent("state.json"))

        await store.addRepo(at: repo)
        XCTAssertEqual(store.repos.count, 1)
        await store.newWorkspace(in: store.repos[0])
        XCTAssertNil(store.errorMessage)
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        XCTAssertTrue(workspace.branch.hasPrefix("psyduck/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path + "/a.txt"))

        // Survives a relaunch.
        let reloaded = AppStore(settings: settings, stateURL: root.appendingPathComponent("state.json"))
        XCTAssertEqual(reloaded.workspaces.map(\.id), [workspace.id])

        await store.archive(workspace)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    /// A chat turn, with a script standing in for claude: the engine's
    /// events have to reach the store's transcript, changes and cost.
    @MainActor
    func testChatTurnReachesTheStore() async throws {
        let claude = root.appendingPathComponent("claude").path
        let script = [
            "#!/bin/sh",
            "cat > /dev/null",
            #"printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1"}'"#,
            #"printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"on it"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo quack > duck.txt"}}]}}'"#,
            "echo quack > duck.txt",
            #"printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"quack"}]}}'"#,
            #"printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":900,"total_cost_usd":0.25,"session_id":"s1"}'"#,
        ].joined(separator: "\n") + "\n"
        try script.write(toFile: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude)

        let settings = AppSettings(defaults: UserDefaults(suiteName: "psyduck-tests-\(UUID().uuidString)")!)
        settings.gitPath = "/usr/bin/git"
        settings.claudePath = claude
        settings.workspacesRoot = root.appendingPathComponent("workspaces").path
        let stateURL = root.appendingPathComponent("state.json")
        let store = AppStore(settings: settings, stateURL: stateURL)
        await store.addRepo(at: root.appendingPathComponent("repo").path)
        await store.newWorkspace(in: store.repos[0])
        let workspace = try XCTUnwrap(store.selectedWorkspace)

        store.send("make a duck", to: workspace.id)
        for _ in 0..<100 where store.selectedWorkspace?.totalCost == nil || store.isRunning(workspace.id) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let transcript = store.transcript(workspace.id)
        XCTAssertFalse(transcript.running)
        XCTAssertEqual(transcript.items.map(\.kind), [.user, .assistant, .tool, .meta])
        XCTAssertEqual(transcript.items[2].output, "quack")
        XCTAssertEqual(store.selectedWorkspace?.totalCost, 0.25)
        XCTAssertEqual(store.selectedWorkspace?.claudeSessionID, "s1")
        await store.refreshChanges(workspace.id)
        XCTAssertEqual(store.changes[workspace.id]?.map(\.path), ["duck.txt"])

        // A relaunch shows the same chat.
        let reloaded = AppStore(settings: settings, stateURL: stateURL)
        XCTAssertEqual(reloaded.transcript(workspace.id).items, transcript.items)
    }
}
