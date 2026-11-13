import XCTest
@testable import Psyduck

final class ClaudeStreamTests: XCTestCase {
    private func parse(_ json: String) -> [ClaudeEvent] { ClaudeStream.parse(Data(json.utf8)) }

    func testInitGivesSessionID() {
        XCTAssertEqual(parse(#"{"type":"system","subtype":"init","session_id":"abc","cwd":"/x"}"#),
                       [.started(sessionID: "abc")])
        XCTAssertEqual(parse(#"{"type":"system","subtype":"hook_started","session_id":"abc"}"#), [])
    }

    func testTextDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi there,"}},"session_id":"s","parent_tool_use_id":null}"#
        XCTAssertEqual(parse(line), [.textDelta("Hi there,")])
    }

    func testAssistantTextAndToolUse() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"on it"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la\nmore","description":"list"}}]},"parent_tool_use_id":null}"#
        XCTAssertEqual(parse(line), [.text("on it"), .toolUse(id: "t1", name: "Bash", summary: "ls -la")])
    }

    func testSubagentMessagesAreIgnored() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"inner"}]},"parent_tool_use_id":"toolu_1"}"#
        XCTAssertEqual(parse(line), [])
    }

    func testFailedToolResult() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"permission denied"}]}}"#
        XCTAssertEqual(parse(line), [.toolResult(id: "t1", isError: true, output: "permission denied")])
        let ok = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"48 runs, 0 failures"}]}]}}"#
        XCTAssertEqual(parse(ok), [.toolResult(id: "t2", isError: false, output: "48 runs, 0 failures")])
    }

    func testResult() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1500,"total_cost_usd":0.01,"session_id":"s2","result":"done"}"#
        XCTAssertEqual(parse(line), [.finished(isError: false, message: nil, durationMs: 1500, costUSD: 0.01, sessionID: "s2")])
    }

    func testGarbageIsIgnored() {
        XCTAssertEqual(parse("not json"), [])
    }

    func testArgumentsResumeAndModel() {
        let args = AppStore.claudeArguments(sessionID: "s1", permissionMode: "acceptEdits", model: " opus ")
        XCTAssertTrue(args.starts(with: ["-p", "--output-format", "stream-json"]))
        XCTAssertTrue(args.contains("--resume"))
        XCTAssertEqual(args.suffix(2), ["--model", "opus"])
        XCTAssertFalse(AppStore.claudeArguments(sessionID: nil, permissionMode: "plan", model: "").contains("--resume"))
    }
}

final class DiffParsingTests: XCTestCase {
    func testChangedFiles() {
        let files = Git.parseChangedFiles(
            numstat: "3\t1\tSources/a.swift\n-\t-\timg.png\n0\t5\told.txt",
            nameStatus: "M\tSources/a.swift\nA\timg.png\nD\told.txt",
            untracked: "new.md\n")
        XCTAssertEqual(files.map(\.path), ["img.png", "new.md", "old.txt", "Sources/a.swift"])
        XCTAssertEqual(files.first { $0.path == "Sources/a.swift" }?.additions, 3)
        XCTAssertEqual(files.first { $0.path == "img.png" }?.additions, nil)
        XCTAssertEqual(files.first { $0.path == "old.txt" }?.status, .deleted)
        XCTAssertEqual(files.first { $0.path == "new.md" }?.status, .untracked)
    }

    func testUnifiedDiffLineNumbers() {
        let text = """
        diff --git a/f b/f
        index 1..2 100644
        --- a/f
        +++ b/f
        @@ -10,3 +10,3 @@ func x()
         keep
        -old
        +new
         tail
        """
        let lines = Git.parseDiff(text)
        XCTAssertEqual(lines.filter { $0.kind == .header }.count, 4)
        let removed = lines.first { $0.kind == .removed }
        let added = lines.first { $0.kind == .added }
        XCTAssertEqual(removed?.text, "old")
        XCTAssertEqual(removed?.oldNumber, 11)
        XCTAssertEqual(added?.newNumber, 11)
        XCTAssertEqual(lines.last?.oldNumber, 12)
        XCTAssertEqual(lines.last?.newNumber, 12)
    }
}

/// Runs real git against a throwaway repo.
final class WorktreeTests: XCTestCase {
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

    func testWorktreeAndDiff() async throws {
        let repo = root.appendingPathComponent("repo").path
        let top = try await git.topLevel(of: repo)
        XCTAssertEqual((top as NSString).resolvingSymlinksInPath, (repo as NSString).resolvingSymlinksInPath)

        let base = await git.defaultBaseRef(repo: repo)
        XCTAssertEqual(base, "main")

        let dir = root.appendingPathComponent("ws/mallard").path
        let commit = try await git.addWorktree(repo: repo, directory: dir, branch: "psyduck/mallard", baseRef: base)
        XCTAssertEqual(commit.count, 40)
        let branchExists = await git.branchExists("psyduck/mallard", repo: repo)
        XCTAssertTrue(branchExists)

        var files = try await git.changedFiles(in: dir, base: commit)
        XCTAssertTrue(files.isEmpty)

        try "one\nTWO\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "hello\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        files = try await git.changedFiles(in: dir, base: commit)
        XCTAssertEqual(files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(files[0].additions, 1)
        XCTAssertEqual(files[1].status, .untracked)

        let modified = Git.parseDiff(try await git.diff(of: files[0], in: dir, base: commit))
        XCTAssertEqual(modified.filter { $0.kind == .added }.map(\.text), ["TWO"])
        let untracked = Git.parseDiff(try await git.diff(of: files[1], in: dir, base: commit))
        XCTAssertEqual(untracked.filter { $0.kind == .added }.map(\.text), ["hello"])

        // The repo's own checkout is untouched.
        let original = try String(contentsOfFile: repo + "/a.txt", encoding: .utf8)
        XCTAssertEqual(original, "one\ntwo\n")

        try await git.removeWorktree(repo: repo, directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
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
}

/// A real chat turn through claude. Slow and billed, so it only runs when
/// asked: TEST_RUNNER_PSYDUCK_LIVE_CLAUDE=1 xcodebuild test … -only-testing:PsyduckTests/LiveClaudeTests
final class LiveClaudeTests: XCTestCase {
    @MainActor
    func testChatTurnEditsTheWorktree() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PSYDUCK_LIVE_CLAUDE"] == "1", "live test")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("psyduck-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Git(gitPath: "/usr/bin/git")
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "t"]] {
            try await git.output(args, in: repo)
        }
        try "hello\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try await git.output(["add", "."], in: repo)
        try await git.output(["commit", "-m", "init"], in: repo)

        let settings = AppSettings(defaults: UserDefaults(suiteName: "psyduck-live-\(UUID().uuidString)")!)
        settings.gitPath = "/usr/bin/git"
        settings.workspacesRoot = root.appendingPathComponent("ws").path
        settings.model = "haiku"
        settings.permissionMode = "acceptEdits"
        if settings.claudePath.isEmpty { settings.claudePath = Shell.home + "/.local/bin/claude" }
        let store = AppStore(settings: settings, stateURL: nil)
        await store.addRepo(at: repo)
        await store.newWorkspace(in: store.repos[0])
        let workspace = try XCTUnwrap(store.selectedWorkspace)

        store.send("Create a file named duck.txt containing exactly the word quack. Then reply with just: done", to: workspace.id)
        for _ in 0..<240 where store.isRunning(workspace.id) { try await Task.sleep(for: .milliseconds(500)) }
        XCTAssertFalse(store.isRunning(workspace.id))

        let items = try XCTUnwrap(store.selectedWorkspace).items
        print("TRANSCRIPT:", items.map { "\($0.kind): \($0.text) \($0.detail ?? "")" })
        XCTAssertFalse(items.contains { $0.kind == .error })
        XCTAssertTrue(items.contains { $0.kind == .tool })
        let shell = items.first { $0.isShell }
        print("SHELL OUTPUT:", shell?.output ?? "nil")
        XCTAssertEqual(shell?.output?.contains("quack"), true, "shell output wasn't captured")
        XCTAssertTrue(items.contains { $0.kind == .assistant })
        XCTAssertNotNil(store.selectedWorkspace?.claudeSessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path + "/duck.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/duck.txt"))
        await store.refreshChanges(workspace.id)
        XCTAssertEqual(store.changes[workspace.id]?.map(\.path), ["duck.txt"])

        // Second turn resumes the same conversation.
        store.send("What file did you just create? Answer with only the filename.", to: workspace.id)
        for _ in 0..<240 where store.isRunning(workspace.id) { try await Task.sleep(for: .milliseconds(500)) }
        let last = store.selectedWorkspace?.items.last { $0.kind == .assistant }?.text ?? ""
        print("SECOND:", last)
        XCTAssertTrue(last.contains("duck.txt"))
    }
}

final class PrimaryActionTests: XCTestCase {
    private let pr = PullRequest(number: 7, url: "https://github.com/o/r/pull/7", state: "OPEN", isDraft: false)

    func testOrder() {
        var s = BranchState(dirty: false, hasRemote: true)
        XCTAssertEqual(PrimaryAction.decide(s), .none)

        s.dirty = true
        XCTAssertEqual(PrimaryAction.decide(s), .createPR, "no PR yet: commit, push and open one")
        s.behind = 2
        XCTAssertEqual(PrimaryAction.decide(s), .pull, "catch up with the remote first")
        s.behind = 0; s.dirty = false

        s.commitsSinceBase = 1
        XCTAssertEqual(PrimaryAction.decide(s), .push, "never pushed")
        s.hasUpstream = true
        XCTAssertEqual(PrimaryAction.decide(s), .createPR)
        s.ahead = 1
        XCTAssertEqual(PrimaryAction.decide(s), .push)
        s.ahead = 0

        s.pr = pr; s.dirty = true
        XCTAssertEqual(PrimaryAction.decide(s), .commitAndPush, "PR open: update it")
        s.dirty = false

        var draft = pr; draft.isDraft = true
        s.pr = draft
        XCTAssertEqual(PrimaryAction.decide(s), .markReady(draft))
        s.pr = pr
        XCTAssertEqual(PrimaryAction.decide(s), .viewPR(pr))
        var merged = pr; merged.state = "MERGED"
        s.pr = merged
        XCTAssertEqual(PrimaryAction.decide(s), .merged(merged))
    }

    func testNoRemoteOnlyCommits() {
        var s = BranchState(dirty: true, hasRemote: false)
        XCTAssertEqual(PrimaryAction.decide(s), .commit)
        s.dirty = false; s.commitsSinceBase = 3
        XCTAssertEqual(PrimaryAction.decide(s), .none)
    }

    /// Real git: a bare "origin", a worktree, then commit → push → behind.
    func testBranchStateAgainstARealRemote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("psyduck-branch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Git(gitPath: "/usr/bin/git")
        let origin = root.appendingPathComponent("origin.git").path
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: origin, withIntermediateDirectories: true)
        try await git.output(["init", "--bare", "-b", "main"], in: origin)
        try await git.output(["clone", origin, repo], in: root.path)
        for args in [["config", "user.email", "t@example.com"], ["config", "user.name", "t"]] {
            try await git.output(args, in: repo)
        }
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try await git.output(["add", "."], in: repo)
        try await git.output(["commit", "-m", "init"], in: repo)
        try await git.output(["push", "-u", "origin", "main"], in: repo)

        let dir = root.appendingPathComponent("ws").path
        let base = try await git.addWorktree(repo: repo, directory: dir, branch: "psyduck/teal", baseRef: "main")
        func state() async -> BranchState {
            await git.branchState(worktree: dir, base: base, branch: "psyduck/teal", gh: nil, network: true, previousPR: nil)
        }

        try "b\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        var s = await state()
        XCTAssertTrue(s.dirty)
        XCTAssertTrue(s.hasRemote)
        XCTAssertEqual(PrimaryAction.decide(s), .createPR)

        try await git.output(["add", "-A"], in: dir)
        try await git.output(["commit", "-m", "b"], in: dir)
        s = await state()
        XCTAssertEqual(PrimaryAction.decide(s), .push)

        try await git.output(["push", "-u", "origin", "HEAD"], in: dir)
        s = await state()
        XCTAssertEqual(s.ahead, 0)
        XCTAssertEqual(PrimaryAction.decide(s), .createPR)

        // Someone else pushes to the branch.
        let other = root.appendingPathComponent("other").path
        try await git.output(["clone", "-b", "psyduck/teal", origin, other], in: root.path)
        for args in [["config", "user.email", "o@example.com"], ["config", "user.name", "o"]] {
            try await git.output(args, in: other)
        }
        try "c\n".write(toFile: other + "/c.txt", atomically: true, encoding: .utf8)
        try await git.output(["add", "."], in: other)
        try await git.output(["commit", "-m", "c"], in: other)
        try await git.output(["push"], in: other)

        s = await state()
        XCTAssertEqual(s.behind, 1)
        XCTAssertEqual(PrimaryAction.decide(s), .pull)
        try await git.output(["pull", "--rebase", "--autostash", "origin", "psyduck/teal"], in: dir)
        s = await state()
        XCTAssertEqual(s.behind, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/c.txt"))
    }
}

extension LiveClaudeTests {
    /// The header button's commit & push, with claude writing the message.
    @MainActor
    func testCommitAndPushWritesAMessage() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PSYDUCK_LIVE_CLAUDE"] == "1", "live test")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("psyduck-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = Git(gitPath: "/usr/bin/git")
        let origin = root.appendingPathComponent("origin.git").path
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: origin, withIntermediateDirectories: true)
        try await git.output(["init", "--bare", "-b", "main"], in: origin)
        try await git.output(["clone", origin, repo], in: root.path)
        for args in [["config", "user.email", "t@example.com"], ["config", "user.name", "t"]] {
            try await git.output(args, in: repo)
        }
        try "hello\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try await git.output(["add", "."], in: repo)
        try await git.output(["commit", "-m", "init"], in: repo)
        try await git.output(["push", "-u", "origin", "main"], in: repo)

        let settings = AppSettings(defaults: UserDefaults(suiteName: "psyduck-live-\(UUID().uuidString)")!)
        settings.gitPath = "/usr/bin/git"
        settings.workspacesRoot = root.appendingPathComponent("ws").path
        if settings.claudePath.isEmpty { settings.claudePath = Shell.home + "/.local/bin/claude" }
        let store = AppStore(settings: settings, stateURL: nil)
        await store.addRepo(at: repo)
        await store.newWorkspace(in: store.repos[0])
        let workspace = try XCTUnwrap(store.selectedWorkspace)

        try "fn add(a, b) = a + b\n".write(toFile: workspace.path + "/math.txt", atomically: true, encoding: .utf8)
        await store.refreshBranch(workspace.id, network: true)
        XCTAssertEqual(store.primaryAction(for: workspace.id), .createPR)

        store.perform(.commitAndPush, on: workspace.id)
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<120 where store.acting.contains(workspace.id) { try await Task.sleep(for: .milliseconds(500)) }

        let message = try await git.output(["log", "-1", "--format=%B"], in: workspace.path)
        print("COMMIT MESSAGE:", message)
        print("NOTES:", store.selectedWorkspace?.items.map(\.text) ?? [])
        XCTAssertFalse(message.hasPrefix("chore: changes from"), "fell back instead of using claude")
        let remote = try await git.output(["ls-remote", "origin", workspace.branch], in: repo)
        XCTAssertFalse(remote.isEmpty, "branch wasn't pushed")
        XCTAssertEqual(store.primaryAction(for: workspace.id), .createPR)
    }
}
