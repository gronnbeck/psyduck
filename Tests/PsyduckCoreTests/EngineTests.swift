import XCTest
@testable import PsyduckCore

/// A throwaway git repo and a stand-in `claude`: a shell script that speaks
/// stream-json, so the engine can be driven end to end with no network.
struct Fixture {
    let root: URL
    let repo: String
    let claude: String
    let git = Git(gitPath: "/usr/bin/git")

    var config: EngineConfig {
        EngineConfig(claudePath: claude, gitPath: "/usr/bin/git",
                     workspacesRoot: root.appendingPathComponent("ws").path,
                     reposRoot: root.appendingPathComponent("repos").path,
                     permissionMode: "acceptEdits", model: "")
    }

    var stateURL: URL { root.appendingPathComponent("data/state.json") }

    /// What the fake claude was last called with.
    var lastArguments: String {
        (try? String(contentsOf: root.appendingPathComponent("bin/args.txt"), encoding: .utf8)) ?? ""
    }
    var lastPrompt: String {
        (try? String(contentsOf: root.appendingPathComponent("bin/prompt.txt"), encoding: .utf8)) ?? ""
    }

    static func make() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("psyduck-engine-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo").path
        let git = Git(gitPath: "/usr/bin/git")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "t"]] {
            try await git.output(args, in: repo)
        }
        try "hello\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try await git.output(["add", "."], in: repo)
        try await git.output(["commit", "-m", "init"], in: repo)

        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude").path
        try fakeClaude.write(toFile: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude)
        return Fixture(root: root, repo: repo, claude: claude)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func engine(stored: Bool = false) -> WorkspaceEngine {
        let storage = EngineStorage(stateURL: stored ? stateURL : nil)
        let config = config
        return WorkspaceEngine(loaded: storage.load(), storage: storage) { config }
    }

    /// The prompt picks the behaviour: "slow" takes a second, "hang" never
    /// finishes, "fail" exits 3 without a result line.
    private static let fakeClaude = #"""
    #!/bin/sh
    here=$(dirname "$0")
    case "$*" in
      *"--output-format text"*) cat > /dev/null; printf '%s\n' 'feat: add duck'; exit 0 ;;
    esac
    prompt=$(cat)
    printf '%s\n' "$*" > "$here/args.txt"
    printf '%s\n' "$prompt" > "$here/prompt.txt"
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1"}'
    printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"par"}}}'
    case "$prompt" in
      *hang*) exec sleep 30 ;;
      *slow*) sleep 1 ;;
    esac
    printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"tly"}}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo quack > duck.txt"}}]}}'
    echo quack > duck.txt
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"quack"}]}}'
    case "$prompt" in
      *fail*) echo boom >&2; exit 3 ;;
    esac
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1200,"total_cost_usd":0.5,"session_id":"s1"}'
    """#.split(separator: "\n").map { $0.drop(while: { $0 == " " }) }.joined(separator: "\n") + "\n"
}

/// Reads a stream until `done` says so, or the timeout passes.
func collect(_ stream: AsyncStream<WorkspaceEvent>, timeout: Double = 20,
             until done: @escaping @Sendable (WorkspaceEvent) -> Bool) async -> [WorkspaceEvent] {
    let reader = Task { () -> [WorkspaceEvent] in
        var seen: [WorkspaceEvent] = []
        for await event in stream {
            seen.append(event)
            if done(event) { break }
        }
        return seen
    }
    let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        reader.cancel()
    }
    let seen = await reader.value
    timer.cancel()
    return seen
}

let isTurnEnded: @Sendable (WorkspaceEvent) -> Bool = { event in
    if case .turnEnded = event.kind { return true }
    return false
}

/// Counts across calls of a `@Sendable` closure. Only ever touched by the
/// one task reading a stream.
final class Counter: @unchecked Sendable {
    var value = 0
}

final class EngineTests: XCTestCase {
    private var fixture: Fixture!

    override func setUp() async throws {
        fixture = try await Fixture.make()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
    }

    private func workspace(in engine: WorkspaceEngine) async throws -> Workspace {
        let repo = try await engine.addRepo(at: fixture.repo)
        return try await engine.newWorkspace(in: repo.id)
    }

    func testWorkspaceIsAWorktreeOnItsOwnBranch() async throws {
        let engine = fixture.engine()
        let workspace = try await workspace(in: engine)
        XCTAssertTrue(workspace.branch.hasPrefix("psyduck/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path + "/README.md"))
        XCTAssertEqual(workspace.baseRef, "main")
        let again = try await engine.addRepo(at: fixture.repo)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.repos.map(\.id), [again.id], "adding a repo twice keeps one")

        try await engine.archive(workspace.id)
        let after = await engine.snapshot()
        XCTAssertTrue(after.workspaces.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        let branchKept = await fixture.git.branchExists(workspace.branch, repo: fixture.repo)
        XCTAssertTrue(branchKept)
    }

    func testTurnBecomesEventsAndATranscript() async throws {
        let engine = fixture.engine()
        let workspace = try await workspace(in: engine)
        let stream = await engine.events(for: workspace.id)
        await engine.send("  make a duck  ", to: workspace.id)
        let events = await collect(stream, until: isTurnEnded)

        XCTAssertEqual(events.map(\.kind), [
            .prompt("make a duck"),
            .sessionStarted("s1"),
            .textDelta("par"),
            .textDelta("tly"),
            .text("working"),
            .toolUse(id: "t1", name: "Bash", summary: "echo quack > duck.txt"),
            .toolResult(id: "t1", isError: false, output: "quack"),
            .turnResult(isError: false, message: nil, durationMs: 1200, costUSD: 0.5, sessionID: "s1"),
            .turnEnded(cancelled: false, partial: nil),
        ])
        // Stored events count up from 1; live-only ones don't take a number.
        XCTAssertEqual(events.filter { !$0.kind.isLiveOnly }.map(\.seq), Array(1...7))
        XCTAssertEqual(events.filter { $0.kind.isLiveOnly }.map(\.seq), [2, 2])
        XCTAssertEqual(fixture.lastPrompt, "make a duck\n")
        XCTAssertFalse(fixture.lastArguments.contains("--resume"))

        let transcript = await engine.transcript(for: workspace.id)
        XCTAssertEqual(transcript.items.map(\.kind), [.user, .assistant, .tool, .meta])
        XCTAssertEqual(transcript.items[2].output, "quack")
        XCTAssertEqual(transcript.items[3].text, "1.2s · $0.500")
        XCTAssertFalse(transcript.running)
        XCTAssertEqual(transcript.streaming, "")
        XCTAssertEqual(transcript.lastSeq, 7)

        // A client that applies the same events gets the same transcript.
        XCTAssertEqual(Transcript(events: events), transcript)

        let saved = await engine.workspace(workspace.id)
        XCTAssertEqual(saved?.claudeSessionID, "s1")
        XCTAssertEqual(saved?.totalCost, 0.5)
        let files = await engine.changedFiles(workspace.id)
        XCTAssertEqual(files.map(\.path), ["duck.txt"])
        let diff = try await engine.diff(of: files[0], in: workspace.id)
        XCTAssertEqual(Git.parseDiff(diff).filter { $0.kind == .added }.map(\.text), ["quack"])

        // The next turn resumes claude's session.
        let second = await engine.events(for: workspace.id, since: transcript.lastSeq)
        await engine.send("again", to: workspace.id)
        _ = await collect(second, until: isTurnEnded)
        XCTAssertTrue(fixture.lastArguments.contains("--resume s1"))
        XCTAssertTrue(fixture.lastArguments.contains("--permission-mode acceptEdits"))
        let total = await engine.workspace(workspace.id)?.totalCost
        XCTAssertEqual(total, 1.0)
    }

    func testReplayAfterASeq() async throws {
        let engine = fixture.engine()
        let workspace = try await workspace(in: engine)
        let live = await engine.events(for: workspace.id)
        await engine.send("go", to: workspace.id)
        _ = await collect(live, until: isTurnEnded)

        let all = await collect(await engine.events(for: workspace.id, since: 0)) { $0.seq == 7 }
        XCTAssertEqual(all.map(\.seq), Array(1...7), "replay has every stored event and no deltas")
        let tail = await collect(await engine.events(for: workspace.id, since: 5)) { $0.seq == 7 }
        XCTAssertEqual(tail.map(\.seq), [6, 7])
    }

    func testFollowUpWaitsForTheTurnToEnd() async throws {
        let engine = fixture.engine()
        let workspace = try await workspace(in: engine)
        let stream = await engine.events(for: workspace.id)
        await engine.send("slow one", to: workspace.id)
        await engine.send("second", to: workspace.id)
        await engine.send("third", to: workspace.id)

        let ended = Counter()
        let events = await collect(stream) { event in
            if isTurnEnded(event) { ended.value += 1 }
            return ended.value == 2
        }
        XCTAssertTrue(events.contains { $0.kind == .queued("second") })
        XCTAssertTrue(events.contains { $0.kind == .queued("second\n\nthird") })
        let prompts = events.compactMap { event -> String? in
            if case .prompt(let text) = event.kind { return text }
            return nil
        }
        XCTAssertEqual(prompts, ["slow one", "second\n\nthird"])
        let transcript = await engine.transcript(for: workspace.id)
        XCTAssertNil(transcript.queued)
        XCTAssertFalse(transcript.running)
    }

    func testStopKeepsThePartialReplyAndDropsTheQueue() async throws {
        let engine = fixture.engine()
        let workspace = try await workspace(in: engine)
        let stream = await engine.events(for: workspace.id)
        await engine.send("hang", to: workspace.id)
        let start = await collect(stream) { $0.kind == .textDelta("par") }
        XCTAssertEqual(start.last?.kind, .textDelta("par"))
        let running = await engine.isRunning(workspace.id)
        XCTAssertTrue(running)

        // Someone joining now gets the reply so far.
        let late = await engine.events(for: workspace.id, since: start.last?.seq ?? 0)
        let first = await collect(late) { _ in true }
        XCTAssertEqual(first.map(\.kind), [.partial("par")])

        await engine.send("later", to: workspace.id)
        await engine.stop(workspace.id)
        let rest = await collect(await engine.events(for: workspace.id, since: 0), until: isTurnEnded)
        XCTAssertEqual(rest.last?.kind, .turnEnded(cancelled: true, partial: "par"))

        let transcript = await engine.transcript(for: workspace.id)
        XCTAssertEqual(transcript.items.map(\.kind), [.user, .meta, .assistant])
        XCTAssertEqual(transcript.items[1].text, "stopped")
        XCTAssertEqual(transcript.items[2].text, "par")
        XCTAssertNil(transcript.queued, "stopping drops the queue")
        try await Task.sleep(nanoseconds: 300_000_000)
        let stillRunning = await engine.isRunning(workspace.id)
        XCTAssertFalse(stillRunning, "the queued message wasn't sent")
    }

    func testClaudeDyingIsAnErrorInTheChat() async throws {
        let engine = fixture.engine()
        let workspace = try await workspace(in: engine)
        let stream = await engine.events(for: workspace.id)
        await engine.send("fail", to: workspace.id)
        let events = await collect(stream, until: isTurnEnded)
        XCTAssertTrue(events.contains { $0.kind == .note("claude exited with status 3: boom", isError: true) })
        let transcript = await engine.transcript(for: workspace.id)
        XCTAssertEqual(transcript.items.last?.kind, .error)
    }

    func testMissingClaudeIsAnErrorAndNoTurn() async throws {
        let storage = EngineStorage(stateURL: nil)
        var config = fixture.config
        config.claudePath = fixture.root.appendingPathComponent("nope").path
        let broken = config
        let engine = WorkspaceEngine(loaded: storage.load(), storage: storage) { broken }
        let workspace = try await workspace(in: engine)
        let stream = await engine.events(for: workspace.id)
        await engine.send("hello", to: workspace.id)
        let events = await collect(stream, until: isTurnEnded)
        XCTAssertEqual(events.first?.kind, .prompt("hello"))
        XCTAssertTrue(events.contains { event in
            if case .note(_, isError: true) = event.kind { return true }
            return false
        })
        let running = await engine.isRunning(workspace.id)
        XCTAssertFalse(running)
    }

    func testCommitAndDiscard() async throws {
        let engine = fixture.engine()
        let workspace = try await workspace(in: engine)
        try "quack\n".write(toFile: workspace.path + "/duck.txt", atomically: true, encoding: .utf8)
        var state = await engine.branchState(workspace.id, network: false)
        XCTAssertEqual(state.map(PrimaryAction.decide), .commit, "no remote: commit only")

        await engine.perform(.commit, on: workspace.id)
        var transcript = await engine.transcript(for: workspace.id)
        XCTAssertEqual(transcript.items.last?.kind, .meta)
        XCTAssertTrue(transcript.items.last?.text.hasSuffix("— feat: add duck") == true, transcript.items.last?.text ?? "")
        let subject = try await fixture.git.output(["log", "-1", "--format=%s"], in: workspace.path)
        XCTAssertEqual(subject, "feat: add duck")
        state = await engine.branchState(workspace.id, network: false)
        XCTAssertEqual(state?.dirty, false)
        XCTAssertEqual(state?.commitsSinceBase, 1)

        try "more\n".write(toFile: workspace.path + "/scratch.txt", atomically: true, encoding: .utf8)
        try "QUACK\n".write(toFile: workspace.path + "/duck.txt", atomically: true, encoding: .utf8)
        await engine.discard(workspace.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path + "/scratch.txt"))
        let duck = try String(contentsOfFile: workspace.path + "/duck.txt", encoding: .utf8)
        XCTAssertEqual(duck, "quack\n")
        transcript = await engine.transcript(for: workspace.id)
        XCTAssertEqual(transcript.items.last?.text, "discarded uncommitted changes")
    }

    func testStateAndLogsSurviveARestart() async throws {
        let engine = fixture.engine(stored: true)
        let workspace = try await workspace(in: engine)
        let stream = await engine.events(for: workspace.id)
        await engine.send("go", to: workspace.id)
        _ = await collect(stream, until: isTurnEnded)
        let before = await engine.transcript(for: workspace.id)

        let storage = EngineStorage(stateURL: fixture.stateURL)
        let loaded = storage.load()
        XCTAssertEqual(loaded.workspaces.map(\.id), [workspace.id])
        XCTAssertEqual(loaded.workspaces.first?.claudeSessionID, "s1")
        XCTAssertEqual(Transcript(events: loaded.events[workspace.id] ?? []), before,
                       "same rows, same ids, after a reload")

        let config = fixture.config
        let reopened = WorkspaceEngine(loaded: loaded, storage: storage) { config }
        let after = await reopened.transcript(for: workspace.id)
        XCTAssertEqual(after, before)

        try await reopened.archive(workspace.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.logURL(for: workspace.id)!.path))
    }
}

final class StorageTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("psyduck-storage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A `state.json` from before the event log: each workspace carries `items`.
    func testOldStateFileMovesItsChatsIntoLogs() throws {
        let workspaceID = UUID()
        let repoID = UUID()
        let old = """
        {"repos":[{"id":"\(repoID.uuidString)","name":"r","path":"/tmp/r"}],
         "workspaces":[{"id":"\(workspaceID.uuidString)","repoID":"\(repoID.uuidString)","name":"teal",
           "branch":"psyduck/teal","path":"/tmp/ws/teal","baseRef":"main","baseCommit":"abc","createdAt":1000,
           "claudeSessionID":"s9","totalCost":0.25,
           "items":[{"id":"\(UUID().uuidString)","kind":"user","text":"hi","isError":false},
                    {"id":"\(UUID().uuidString)","kind":"tool","text":"Bash","detail":"ls","isError":false,"toolID":"t1","output":"a.txt"},
                    {"id":"\(UUID().uuidString)","kind":"assistant","text":"hello","isError":false}]}]}
        """
        let stateURL = root.appendingPathComponent("state.json")
        try old.write(to: stateURL, atomically: true, encoding: .utf8)
        let storage = EngineStorage(stateURL: stateURL)

        let loaded = storage.load()
        XCTAssertEqual(loaded.workspaces.first?.claudeSessionID, "s9")
        XCTAssertEqual(loaded.workspaces.first?.totalCost, 0.25)
        let transcript = Transcript(events: loaded.events[workspaceID] ?? [])
        XCTAssertEqual(transcript.items.map(\.text), ["hi", "Bash", "hello"])
        XCTAssertEqual(transcript.items[1].output, "a.txt")
        XCTAssertFalse(transcript.running)

        // The old file is kept, the new one has no chat in it, and a second
        // load doesn't migrate again.
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("state.v1.json"), encoding: .utf8), old)
        XCTAssertFalse(try String(contentsOf: stateURL, encoding: .utf8).contains("\"items\""))
        let again = storage.load()
        XCTAssertEqual(again.events[workspaceID]?.count, 3)
        XCTAssertEqual(Transcript(events: again.events[workspaceID] ?? []), transcript)
    }

    func testATurnCutOffByQuittingIsClosedOnLoad() throws {
        let stateURL = root.appendingPathComponent("state.json")
        let storage = EngineStorage(stateURL: stateURL)
        let workspace = Workspace(repoID: UUID(), name: "teal", branch: "psyduck/teal", path: "/tmp/x",
                                  baseRef: "main", baseCommit: "abc")
        storage.save(repos: [], workspaces: [workspace])
        var log = EventLog(url: storage.logURL(for: workspace.id))
        log.append(.prompt("do it"))
        log.append(.text("on it"))

        let transcript = Transcript(events: storage.load().events[workspace.id] ?? [])
        XCTAssertFalse(transcript.running)
        XCTAssertEqual(transcript.items.map(\.kind), [.user, .assistant, .meta])
        XCTAssertTrue(transcript.items.last?.text.hasPrefix("interrupted") == true)
        XCTAssertEqual(storage.load().events[workspace.id]?.count, 4, "closed once, not on every load")
    }

    func testLogSkipsATornLine() throws {
        let url = root.appendingPathComponent("events/x.jsonl")
        var log = EventLog(url: url)
        log.append(.prompt("one"))
        log.append(.text("two"))
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":3,"at":"2026-11-15T10:00:00Z","type":"te"#.utf8))
        try handle.close()
        XCTAssertEqual(EventLog.read(url).map(\.kind), [.prompt("one"), .text("two")])
    }
}

final class EventTests: XCTestCase {
    func testEveryKindRoundTrips() throws {
        let kinds: [WorkspaceEvent.Kind] = [
            .prompt("hi"), .queued("next"), .sessionStarted("s1"), .textDelta("a"), .partial("ab"), .text("abc"),
            .toolUse(id: "t1", name: "Bash", summary: "ls"),
            .toolResult(id: "t1", isError: true, output: "nope"),
            .turnResult(isError: false, message: nil, durationMs: 10, costUSD: 0.1, sessionID: "s1"),
            .turnResult(isError: true, message: "bad", durationMs: nil, costUSD: nil, sessionID: nil),
            .turnEnded(cancelled: true, partial: "par"), .turnEnded(cancelled: false, partial: nil),
            .note("committed", isError: false),
            .legacy(ChatItem(kind: .tool, text: "Bash", detail: "ls", toolID: "t1", output: "x")),
        ]
        for (index, kind) in kinds.enumerated() {
            let event = WorkspaceEvent(seq: index + 1, at: Date(timeIntervalSince1970: 1_800_000_000), kind: kind)
            let data = try EventLog.encoder.encode(event)
            XCTAssertEqual(try EventLog.decoder.decode(WorkspaceEvent.self, from: data), event)
        }
    }

    func testWireFormatIsFlat() throws {
        let event = WorkspaceEvent(seq: 3, at: Date(timeIntervalSince1970: 1_800_000_000),
                                   kind: .toolUse(id: "t1", name: "Bash", summary: "ls"))
        let json = String(decoding: try EventLog.encoder.encode(event), as: UTF8.self)
        XCTAssertEqual(json, #"{"at":"2027-01-15T08:00:00Z","id":"t1","name":"Bash","seq":3,"summary":"ls","type":"tool_use"}"#)
    }

    func testRowIDsComeFromTheEvent() {
        XCTAssertEqual(Transcript.itemID(7), Transcript.itemID(7))
        XCTAssertNotEqual(Transcript.itemID(7), Transcript.itemID(8))
        XCTAssertNotEqual(Transcript.itemID(7), Transcript.itemID(7, slot: 1))
    }
}

/// Real turns through claude. Slow and billed, so they only run when asked:
///   PSYDUCK_LIVE_CLAUDE=1 swift test --filter LiveClaudeTests
final class LiveClaudeTests: XCTestCase {
    private func liveEngine(_ fixture: Fixture, model: String) -> WorkspaceEngine {
        var config = fixture.config
        config.claudePath = ""
        config.model = model
        let live = config
        return WorkspaceEngine { live }
    }

    func testChatTurnEditsTheWorktree() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PSYDUCK_LIVE_CLAUDE"] == "1", "live test")
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let engine = liveEngine(fixture, model: "haiku")
        let repo = try await engine.addRepo(at: fixture.repo)
        let workspace = try await engine.newWorkspace(in: repo.id)

        var stream = await engine.events(for: workspace.id)
        await engine.send("Create a file named duck.txt containing exactly the word quack. Then reply with just: done", to: workspace.id)
        _ = await collect(stream, timeout: 180, until: isTurnEnded)

        var transcript = await engine.transcript(for: workspace.id)
        print("TRANSCRIPT:", transcript.items.map { "\($0.kind): \($0.text) \($0.detail ?? "")" })
        XCTAssertFalse(transcript.running)
        XCTAssertFalse(transcript.items.contains { $0.kind == .error })
        XCTAssertTrue(transcript.items.contains { $0.kind == .tool })
        XCTAssertTrue(transcript.items.contains { $0.kind == .assistant })
        XCTAssertNotNil(transcript.sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path + "/duck.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repo + "/duck.txt"))
        let files = await engine.changedFiles(workspace.id)
        XCTAssertEqual(files.map(\.path), ["duck.txt"])

        // Second turn resumes the same conversation.
        stream = await engine.events(for: workspace.id, since: transcript.lastSeq)
        await engine.send("What file did you just create? Answer with only the filename.", to: workspace.id)
        _ = await collect(stream, timeout: 180, until: isTurnEnded)
        transcript = await engine.transcript(for: workspace.id)
        let last = transcript.items.last { $0.kind == .assistant }?.text ?? ""
        print("SECOND:", last)
        XCTAssertTrue(last.contains("duck.txt"))
    }

    /// The commit action, with claude writing the message.
    func testCommitWritesAMessage() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PSYDUCK_LIVE_CLAUDE"] == "1", "live test")
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let engine = liveEngine(fixture, model: "")
        let repo = try await engine.addRepo(at: fixture.repo)
        let workspace = try await engine.newWorkspace(in: repo.id)

        try "fn add(a, b) = a + b\n".write(toFile: workspace.path + "/math.txt", atomically: true, encoding: .utf8)
        await engine.perform(.commit, on: workspace.id)
        let message = try await fixture.git.output(["log", "-1", "--format=%B"], in: workspace.path)
        print("COMMIT MESSAGE:", message)
        XCTAssertFalse(message.hasPrefix("chore: changes from"), "fell back instead of using claude")
        XCTAssertFalse(message.hasPrefix("init"), "nothing was committed")
    }
}
