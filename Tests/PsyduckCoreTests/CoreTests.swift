import XCTest
import PsyduckCore

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
        let args = ClaudeStream.arguments(sessionID: "s1", permissionMode: "acceptEdits", model: " opus ")
        XCTAssertTrue(args.starts(with: ["-p", "--output-format", "stream-json"]))
        XCTAssertTrue(args.contains("--resume"))
        XCTAssertEqual(args.suffix(2), ["--model", "opus"])
        XCTAssertFalse(ClaudeStream.arguments(sessionID: nil, permissionMode: "plan", model: "").contains("--resume"))
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

    /// A clone whose local main is behind origin, with something else
    /// checked out: the workspace still starts from origin's newest commit.
    func testNewWorkspacesStartFromTheRemoteDefaultBranch() async throws {
        let seed = root.appendingPathComponent("repo").path
        let origin = root.appendingPathComponent("origin.git").path
        let clone = root.appendingPathComponent("clone").path
        try await git.output(["clone", "--bare", seed, origin], in: root.path)
        try await git.output(["clone", origin, clone], in: root.path)
        for args in [["config", "user.email", "t@example.com"], ["config", "user.name", "t"],
                     ["checkout", "-b", "my-feature"]] {
            try await git.output(args, in: clone)
        }
        try "local only\n".write(toFile: clone + "/local.txt", atomically: true, encoding: .utf8)
        try await git.output(["add", "."], in: clone)
        try await git.output(["commit", "-m", "unpushed work"], in: clone)

        // Someone else pushes to origin's main after the clone was made.
        try "upstream\n".write(toFile: seed + "/upstream.txt", atomically: true, encoding: .utf8)
        try await git.output(["add", "."], in: seed)
        try await git.output(["commit", "-m", "upstream"], in: seed)
        try await git.output(["push", origin, "main"], in: seed)
        let upstream = try await git.output(["rev-parse", "HEAD"], in: seed)

        let base = await git.defaultBaseRef(repo: clone)
        XCTAssertEqual(base, "origin/main")
        let dir = root.appendingPathComponent("ws/teal").path
        let commit = try await git.addWorktree(repo: clone, directory: dir, branch: "psyduck/teal", baseRef: base)
        XCTAssertEqual(commit, upstream)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/upstream.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/local.txt"))
    }

    /// Merging the base branch in must not list upstream's files as changes.
    func testChangesAreMeasuredFromWhereTheBranchMetItsBase() async throws {
        let seed = root.appendingPathComponent("repo").path
        let origin = root.appendingPathComponent("origin.git").path
        let clone = root.appendingPathComponent("clone").path
        try await git.output(["clone", "--bare", seed, origin], in: root.path)
        try await git.output(["clone", origin, clone], in: root.path)
        let dir = root.appendingPathComponent("ws/teal").path
        let commit = try await git.addWorktree(repo: clone, directory: dir, branch: "psyduck/teal", baseRef: "origin/main")
        for args in [["config", "user.email", "t@example.com"], ["config", "user.name", "t"]] {
            try await git.output(args, in: dir)
        }
        try "mine\n".write(toFile: dir + "/mine.txt", atomically: true, encoding: .utf8)
        try await git.output(["add", "."], in: dir)
        try await git.output(["commit", "-m", "mine"], in: dir)

        try "upstream\n".write(toFile: seed + "/upstream.txt", atomically: true, encoding: .utf8)
        try await git.output(["add", "."], in: seed)
        try await git.output(["commit", "-m", "upstream"], in: seed)
        try await git.output(["push", origin, "main"], in: seed)
        try await git.output(["fetch", "origin"], in: dir)
        try await git.output(["merge", "--no-edit", "origin/main"], in: dir)

        let stale = try await git.changedFiles(in: dir, base: commit)
        XCTAssertEqual(stale.map(\.path), ["mine.txt", "upstream.txt"])
        let base = await git.diffBase(in: dir, baseRef: "origin/main", baseCommit: commit)
        let files = try await git.changedFiles(in: dir, base: base)
        XCTAssertEqual(files.map(\.path), ["mine.txt"])
    }

    /// `git remote add` records no origin/HEAD; the remote is asked.
    func testFindsTheDefaultBranchWhenOriginHeadIsNotRecorded() async throws {
        let seed = root.appendingPathComponent("repo").path
        let origin = root.appendingPathComponent("origin.git").path
        try await git.output(["clone", "--bare", seed, origin], in: root.path)
        try await git.output(["remote", "add", "origin", origin], in: seed)
        try await git.output(["checkout", "-b", "elsewhere"], in: seed)

        let base = await git.defaultBaseRef(repo: seed)
        XCTAssertEqual(base, "origin/main")
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

final class ShellTests: XCTestCase {
    func testStreamsLinesAndCollectsStderr() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "cat; echo two; echo oops >&2; exit 3"], input: Data("one\n".utf8))
        XCTAssertEqual(result.stdout, "one\ntwo\n")
        XCTAssertEqual(result.stderr, "oops\n")
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.failureLine, "oops")
    }

    /// Cancelling has to actually stop the child. On Linux it once didn't:
    /// the child inherited a signal mask that blocked SIGTERM.
    func testCancellingStopsTheProcess() async throws {
        let started = Date()
        let task = Task {
            try await Shell.run("/bin/sh", ["-c", "exec sleep 30"])
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let result = try await task.value
        XCTAssertFalse(result.ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testSomethingThatCannotBeRunThrows() async {
        do {
            // A directory passes the "is it executable" check and then fails to launch.
            _ = try await Shell.run(FileManager.default.temporaryDirectory.path, [])
            XCTFail("should have thrown")
        } catch {
            XCTAssertTrue(error is ShellError)
        }
        do {
            _ = try await Shell.run("/nonexistent/tool", [])
            XCTFail("should have thrown")
        } catch {
            XCTAssertTrue(error is ShellError)
        }
    }
}
