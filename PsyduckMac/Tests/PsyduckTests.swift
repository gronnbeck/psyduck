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

        // Renaming moves the name and the branch together; the folder stays.
        let tip = try await Git(gitPath: "/usr/bin/git").output(["rev-parse", workspace.branch], in: repo)
        let renameProblem = await store.rename(workspace, to: "  fix login ")
        XCTAssertNil(renameProblem)
        var renamed = try XCTUnwrap(store.selectedWorkspace)
        XCTAssertEqual(renamed.name, "fix-login")
        XCTAssertEqual(renamed.branch, "psyduck/fix-login")
        XCTAssertEqual(renamed.path, workspace.path)
        let movedTip = try await Git(gitPath: "/usr/bin/git").output(["rev-parse", "psyduck/fix-login"], in: repo)
        XCTAssertEqual(movedTip, tip)
        let checkedOut = try await Git(gitPath: "/usr/bin/git").output(["rev-parse", "--abbrev-ref", "HEAD"], in: workspace.path)
        XCTAssertEqual(checkedOut, "psyduck/fix-login")
        let oldBranchExists = await Git(gitPath: "/usr/bin/git").branchExists(workspace.branch, repo: repo)
        XCTAssertFalse(oldBranchExists)

        // A name with its own prefix is the branch as typed.
        let prefixedProblem = await store.rename(renamed, to: "feat/login")
        XCTAssertNil(prefixedProblem)
        renamed = try XCTUnwrap(store.selectedWorkspace)
        XCTAssertEqual(renamed.branch, "feat/login")

        // Names git can't use, and branches that exist, are refused and change nothing.
        let invalid = await store.rename(renamed, to: "bad..name")
        XCTAssertNotNil(invalid)
        try await Git(gitPath: "/usr/bin/git").output(["branch", "psyduck/taken"], in: repo)
        let taken = await store.rename(renamed, to: "taken")
        XCTAssertNotNil(taken)
        XCTAssertEqual(store.selectedWorkspace?.branch, "feat/login")

        // And back, so the rest of the test sees the workspace it started with.
        let backProblem = await store.rename(renamed, to: workspace.name)
        XCTAssertNil(backProblem)
        XCTAssertEqual(store.selectedWorkspace, workspace)

        // Survives a relaunch.
        let reloaded = AppStore(settings: settings, stateURL: root.appendingPathComponent("state.json"))
        XCTAssertEqual(reloaded.workspaces.map(\.id), [workspace.id])

        // Uncommitted work survives archiving, on a ref, without moving the branch.
        try "wip\n".write(toFile: workspace.path + "/wip.txt", atomically: true, encoding: .utf8)
        let git = Git(gitPath: "/usr/bin/git")
        let head = try await git.output(["rev-parse", workspace.branch], in: repo)

        await store.archive(workspace)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        let branchHead = try await git.output(["rev-parse", workspace.branch], in: repo)
        XCTAssertEqual(branchHead, head)

        let archived = try XCTUnwrap(store.loadArchive().first)
        XCTAssertEqual(archived.id, workspace.id)
        XCTAssertNotNil(archived.archivedAt)
        let work = try XCTUnwrap(archived.archivedWork)
        let saved = try await git.output(["show", "\(work):wip.txt"], in: repo)
        XCTAssertEqual(saved, "wip")

        // Archived workspaces aren't loaded at launch.
        let relaunched = AppStore(settings: settings, stateURL: root.appendingPathComponent("state.json"))
        XCTAssertTrue(relaunched.workspaces.isEmpty)
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

    /// A remote host, as a second engine in this process behind the wire
    /// protocol: its workspaces show beside this Mac's and a turn on it
    /// reaches the store.
    @MainActor
    func testARemoteHostsWorkspacesShowBesideTheLocalOnes() async throws {
        let claude = root.appendingPathComponent("claude").path
        let script = [
            "#!/bin/sh",
            "cat > /dev/null",
            #"printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1"}'"#,
            #"printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"on it"}]}}'"#,
            "echo quack > duck.txt",
            #"printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":900,"total_cost_usd":0.25,"session_id":"s1"}'"#,
        ].joined(separator: "\n") + "\n"
        try script.write(toFile: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude)

        // The host: its own engine, config and folders.
        let hostConfig = EngineConfig(claudePath: claude, gitPath: "/usr/bin/git",
                                      workspacesRoot: root.appendingPathComponent("host/workspaces").path,
                                      reposRoot: root.appendingPathComponent("host/repos").path)
        let server = RemoteServer(engine: WorkspaceEngine { hostConfig }, host: "studio")

        let settings = AppSettings(defaults: UserDefaults(suiteName: "psyduck-tests-\(UUID().uuidString)")!)
        settings.gitPath = "/usr/bin/git"
        settings.workspacesRoot = root.appendingPathComponent("workspaces").path
        let host = RemoteHost(name: "studio", command: "in-process")
        settings.hosts = [host]
        let store = AppStore(settings: settings, stateURL: nil) { _ in
            RemoteEngine {
                let (near, far) = try LineConnection.pair()
                Task { await server.serve(far) }
                return near
            }
        }
        try await wait("the host connects") { store.isConnected(host.id) }
        XCTAssertEqual(store.hostStatus[host.id], .connected("studio"))

        // One repo here, one cloned on the host.
        let repoPath = root.appendingPathComponent("repo").path
        await store.addRepo(at: repoPath)
        await store.cloneRepo(repoPath, on: host)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.repos.count, 2)
        let theirs = try XCTUnwrap(store.repos(on: host.id).first)
        XCTAssertEqual(store.repos(on: nil).count, 1)
        XCTAssertEqual(store.host(of: theirs), host)
        XCTAssertTrue(theirs.path.contains("/host/repos/"), theirs.path)

        await store.newWorkspace(in: theirs)
        XCTAssertNil(store.errorMessage)
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        XCTAssertEqual(workspace.repoID, theirs.id)
        XCTAssertTrue(workspace.path.contains("/host/workspaces/"), workspace.path)

        XCTAssertTrue(store.send("add a duck", to: workspace.id))
        try await wait("the turn ends") {
            let transcript = store.transcript(workspace.id)
            return !transcript.running && transcript.items.contains { $0.kind == .meta }
        }
        XCTAssertEqual(store.transcript(workspace.id).items.map(\.kind), [.user, .assistant, .meta])
        try await wait("the change shows") { store.changes[workspace.id]?.map(\.path) == ["duck.txt"] }
        let file = try XCTUnwrap(store.changes[workspace.id]?.first)
        let diff = try await store.diff(of: file, in: workspace)
        XCTAssertTrue(diff.contains("+quack"))

        // Taking the host out of settings takes its workspaces out of the window.
        settings.hosts = []
        try await wait("the host's repos go") { store.repos.count == 1 }
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.hostStatus[host.id])
    }

    @MainActor
    private func wait(_ what: String, timeout: Double = 20, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > deadline { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
