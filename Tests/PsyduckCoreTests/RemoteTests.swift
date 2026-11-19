import XCTest
@testable import PsyduckCore

/// A real engine behind `RemoteServer`, and a `RemoteEngine` talking to it
/// over a socket pair: everything but ssh.
final class RemoteTests: XCTestCase {
    private var fixture: Fixture!

    override func setUp() async throws {
        fixture = try await Fixture.make()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
    }

    /// A client whose every connection is a fresh socket pair to `server`.
    private func client(of server: RemoteServer) -> RemoteEngine {
        RemoteEngine {
            let (near, far) = try LineConnection.pair()
            Task { await server.serve(far) }
            return near
        }
    }

    private func connected(_ remote: RemoteEngine) async {
        await remote.start()
        for await status in remote.statuses {
            if case .connected = status { return }
        }
    }

    func testAWorkspaceAndATurnOverTheWire() async throws {
        let server = RemoteServer(engine: fixture.engine(), host: "studio")
        let remote = client(of: server)
        await connected(remote)
        let status = await remote.status
        XCTAssertEqual(status, .connected("studio"))

        let repo = try await remote.addRepo(at: fixture.repo)
        let workspace = try await remote.newWorkspace(in: repo.id)
        let snapshot = await remote.snapshot()
        XCTAssertEqual(snapshot.repos.map(\.id), [repo.id])
        XCTAssertEqual(snapshot.workspaces.map(\.id), [workspace.id])

        let stream = await remote.events(for: workspace.id, since: 0)
        await remote.send("add a duck", to: workspace.id)
        let events = await collect(stream, until: isTurnEnded)
        XCTAssertTrue(isTurnEnded(try XCTUnwrap(events.last)))
        let transcript = Transcript(events: events)
        XCTAssertEqual(transcript.items.map(\.kind), [.user, .assistant, .tool, .meta])
        XCTAssertFalse(transcript.running)
        let local = await server.engine.transcript(for: workspace.id)
        XCTAssertEqual(transcript, local, "the client builds the same chat the host has")

        let files = await remote.changedFiles(workspace.id)
        XCTAssertEqual(files.map(\.path), ["duck.txt"])
        let diff = try await remote.diff(of: files[0], in: workspace.id)
        XCTAssertTrue(diff.contains("+quack"))
        let dirty = await remote.branchState(workspace.id, network: false)
        XCTAssertEqual(dirty?.dirty, true)

        await remote.perform(.commit, on: workspace.id)
        let clean = await remote.branchState(workspace.id, network: false)
        XCTAssertEqual(clean?.dirty, false)
        XCTAssertEqual(clean?.commitsSinceBase, 1)

        try await remote.rename(workspace.id, to: "fix login")
        let renamed = await remote.snapshot().workspaces.first
        XCTAssertEqual(renamed?.branch, "psyduck/fix-login")

        try await remote.archive(workspace.id)
        let after = await remote.snapshot()
        XCTAssertTrue(after.workspaces.isEmpty)
        await remote.shutDown()
    }

    func testTheHostsRefusalsArriveAsItWroteThem() async throws {
        let server = RemoteServer(engine: fixture.engine())
        let remote = client(of: server)
        await connected(remote)
        let repo = try await remote.addRepo(at: fixture.repo)
        let workspace = try await remote.newWorkspace(in: repo.id)

        do {
            try await remote.rename(workspace.id, to: "bad..name")
            XCTFail("should be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't a valid branch name"), error.localizedDescription)
        }
        do {
            _ = try await remote.addRepo(at: fixture.root.appendingPathComponent("nowhere").path)
            XCTFail("should be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't a git repository"), error.localizedDescription)
        }
        await remote.shutDown()
    }

    /// The agent keeps going on the host when the client drops; coming back,
    /// the client asks for what it missed.
    func testATurnOutlivesTheConnection() async throws {
        let engine = fixture.engine()
        let server = RemoteServer(engine: engine)
        let links = Links()
        let remote = RemoteEngine {
            let (near, far) = try LineConnection.pair()
            links.add(near)
            Task { await server.serve(far) }
            return near
        }
        await connected(remote)
        let repo = try await remote.addRepo(at: fixture.repo)
        let workspace = try await remote.newWorkspace(in: repo.id)

        let first = await remote.events(for: workspace.id, since: 0)
        await remote.send("slow duck", to: workspace.id)
        let seen = await collect(first) { event in
            if case .sessionStarted = event.kind { return true }
            return false
        }
        let lastSeq = try XCTUnwrap(seen.last?.seq)

        // The network goes away mid-turn.
        links.cutAll()
        for await status in remote.statuses {
            if case .connected = status { break }
        }
        let rest = await collect(await remote.events(for: workspace.id, since: lastSeq), until: isTurnEnded)
        XCTAssertTrue(rest.allSatisfy { $0.seq >= lastSeq })
        let whole = Transcript(events: seen.filter { !$0.kind.isLiveOnly } + rest)
        let local = await engine.transcript(for: workspace.id)
        XCTAssertEqual(whole.items, local.items)
        XCTAssertFalse(whole.running)
        await remote.shutDown()
    }

    func testAHostThatCannotBeReachedSaysWhy() async throws {
        let remote = RemoteEngine(command: "echo 'ssh: Could not resolve hostname nowhere' >&2; exit 255")
        await remote.start()
        var reason = ""
        for await status in remote.statuses {
            if case .offline(let why) = status { reason = why; break }
        }
        XCTAssertEqual(reason, "ssh: Could not resolve hostname nowhere")
        do {
            _ = try await remote.addRepo(at: "/tmp")
            XCTFail("offline")
        } catch {
            XCTAssertEqual(error.localizedDescription, reason)
        }
        await remote.shutDown()
    }

    /// The whole path a real host uses: a listening socket, and a client
    /// that reaches it by running a command that pipes stdio to it.
    func testThroughAListeningSocketAndAProcess() async throws {
        try XCTSkipUnless(["/usr/bin/nc", "/bin/nc"].contains { FileManager.default.isExecutableFile(atPath: $0) },
                          "needs nc")
        let socket = "/tmp/psy-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixListener(path: socket)
        defer { listener.close() }
        let server = RemoteServer(engine: fixture.engine(), host: "box")
        Task { await server.serve(listener) }

        XCTAssertThrowsError(try UnixListener(path: socket), "a second server on the same socket is refused")

        // `nc -U` stands in for `ssh host psyduck attach`.
        let remote = RemoteEngine(command: "nc -U \(socket)")
        await connected(remote)
        let repo = try await remote.addRepo(at: fixture.repo)
        let again = await remote.snapshot()
        XCTAssertEqual(again.repos.map(\.id), [repo.id])
        await remote.shutDown()
    }
}

final class ConfigFileTests: XCTestCase {
    func testAConfigFileFillsInWhatItNames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("psyduck-config-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(EngineConfig.load(from: url), EngineConfig(), "no file is the defaults")
        try #"{"model":"sonnet","workspacesRoot":"/data/workspaces"}"#.write(to: url, atomically: true, encoding: .utf8)
        let config = EngineConfig.load(from: url)
        XCTAssertEqual(config.model, "sonnet")
        XCTAssertEqual(config.workspacesRoot, "/data/workspaces")
        XCTAssertEqual(config.permissionMode, EngineConfig.defaultPermissionMode)
    }
}

/// The client ends of the connections made so far, so a test can cut them.
final class Links: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [LineConnection] = []

    func add(_ connection: LineConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }

    func cutAll() {
        lock.lock()
        let all = connections
        connections = []
        lock.unlock()
        for connection in all { connection.close() }
    }
}
