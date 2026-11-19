import Foundation

/// Answers clients on behalf of an engine: what `psyduck serve` runs for
/// each connection. The engine keeps working whether anyone is connected.
public struct RemoteServer: Sendable {
    public let engine: WorkspaceEngine
    /// The machine's name, shown in the app beside the host.
    public let host: String

    public init(engine: WorkspaceEngine, host: String = ProcessInfo.processInfo.hostName) {
        self.engine = engine
        self.host = host
    }

    /// Serves every connection the listener accepts, until it closes.
    public func serve(_ listener: UnixListener) async {
        await withTaskGroup(of: Void.self) { group in
            for await connection in listener.connections {
                group.addTask { await serve(connection) }
            }
        }
    }

    /// Serves one client until it hangs up. Each call runs on its own, so a
    /// slow one (a clone, a commit) doesn't hold up the rest.
    public func serve(_ connection: LineConnection) async {
        let subscriptions = Subscriptions()
        await withTaskGroup(of: Void.self) { group in
            for await line in connection.lines {
                guard let request = try? Wire.decoder().decode(Wire.Request.self, from: line) else {
                    Self.send(Wire.Message(error: "that isn't a request psyduck understands"), on: connection)
                    continue
                }
                group.addTask {
                    await answer(request, on: connection, subscriptions: subscriptions)
                }
            }
            await subscriptions.cancelAll()
            group.cancelAll()
        }
        connection.close()
    }

    private static func send(_ message: Wire.Message, on connection: LineConnection) {
        if let data = try? Wire.encoder().encode(message) { connection.send(data) }
    }

    private func answer(_ request: Wire.Request, on connection: LineConnection, subscriptions: Subscriptions) async {
        do {
            let result = try await run(request, on: connection, subscriptions: subscriptions)
            Self.send(Wire.Message(id: request.id, result: result), on: connection)
        } catch {
            Self.send(Wire.Message(id: request.id, error: error.localizedDescription), on: connection)
        }
    }

    private func run(_ request: Wire.Request, on connection: LineConnection,
                     subscriptions: Subscriptions) async throws -> Wire.Result {
        let params = request.params ?? Wire.Params()
        func workspace() throws -> UUID {
            guard let id = params.workspace else { throw EngineError.unknownWorkspace }
            return id
        }
        func repo() throws -> UUID {
            guard let id = params.repo else { throw EngineError.unknownRepo }
            return id
        }

        switch request.method {
        case .hello:
            return Wire.Result(version: Wire.version, host: host)

        case .snapshot:
            let snapshot = await engine.snapshot()
            return Wire.Result(repos: snapshot.repos, workspaces: snapshot.workspaces)

        case .events:
            let id = try workspace()
            guard let sub = params.sub else { throw ConnectionError.failed("events needs a sub") }
            let stream = await engine.events(for: id, since: params.since ?? 0)
            let task = Task {
                for await event in stream {
                    Self.send(Wire.Message(sub: sub, event: event), on: connection)
                }
                if !Task.isCancelled { Self.send(Wire.Message(sub: sub, ended: true), on: connection) }
            }
            await subscriptions.add(task, as: sub)
            return Wire.Result()

        case .unsubscribe:
            if let sub = params.sub { await subscriptions.cancel(sub) }
            return Wire.Result()

        case .addRepo:
            return Wire.Result(repo: try await engine.addRepo(at: params.path ?? ""))
        case .cloneRepo:
            return Wire.Result(repo: try await engine.cloneRepo(params.url ?? ""))
        case .removeRepo:
            await engine.removeRepo(try repo())
            return Wire.Result()

        case .newWorkspace:
            return Wire.Result(workspace: try await engine.newWorkspace(in: try repo(), prompt: params.text))
        case .rename:
            try await engine.rename(try workspace(), to: params.name ?? "")
            return Wire.Result()
        case .archive:
            try await engine.archive(try workspace())
            return Wire.Result()

        case .send:
            await engine.send(params.text ?? "", to: try workspace())
            return Wire.Result()
        case .stop:
            await engine.stop(try workspace())
            return Wire.Result()

        case .changedFiles:
            return Wire.Result(files: await engine.changedFiles(try workspace()))
        case .diff:
            guard let file = params.file else { throw ConnectionError.failed("diff needs a file") }
            return Wire.Result(diff: try await engine.diff(of: file, in: try workspace()))
        case .branchState:
            return Wire.Result(branch: await engine.branchState(try workspace(), network: params.network ?? false))
        case .perform:
            if let action = params.action { await engine.perform(action, on: try workspace()) }
            return Wire.Result()
        case .discard:
            await engine.discard(try workspace())
            return Wire.Result()
        }
    }

    /// One connection's event subscriptions, by the client's number.
    private actor Subscriptions {
        private var tasks: [Int: Task<Void, Never>] = [:]

        func add(_ task: Task<Void, Never>, as sub: Int) {
            tasks[sub]?.cancel()
            tasks[sub] = task
        }

        func cancel(_ sub: Int) {
            tasks[sub]?.cancel()
            tasks[sub] = nil
        }

        func cancelAll() {
            for task in tasks.values { task.cancel() }
            tasks = [:]
        }
    }
}
