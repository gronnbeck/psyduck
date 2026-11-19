import Foundation

public enum RemoteError: LocalizedError {
    case offline(String)
    /// What the server said went wrong, in its words.
    case server(String)
    case version(Int)

    public var errorDescription: String? {
        switch self {
        case .offline(let reason): return reason.isEmpty ? "the host isn't connected" : reason
        case .server(let message): return message
        case .version(let theirs):
            return "the host runs a different psyduck (protocol \(theirs), this app speaks \(Wire.version)). Update one of them."
        }
    }
}

/// An engine on another machine. It keeps one connection open, reconnects
/// when it drops, and answers the same calls as a local engine. Turns keep
/// running on the host whether or not this is connected; a listener that
/// was cut off asks again from the last event it saw.
public actor RemoteEngine: EngineClient {
    public enum Status: Equatable, Sendable {
        case connecting
        /// Connected; the string is the machine's own name.
        case connected(String)
        /// Not connected, and why. It keeps trying.
        case offline(String)
    }

    public typealias Connect = @Sendable () async throws -> LineConnection

    private let connect: Connect
    private var connection: LineConnection?
    private var loop: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Wire.Result, Error>] = [:]
    private var subscriptions: [Int: AsyncStream<WorkspaceEvent>.Continuation] = [:]

    public private(set) var status: Status = .connecting
    /// Every change of `status`, for whoever shows it.
    public nonisolated let statuses: AsyncStream<Status>
    private let statusContinuation: AsyncStream<Status>.Continuation

    /// `connect` opens a fresh connection each time one is needed.
    public init(connect: @escaping Connect) {
        self.connect = connect
        (statuses, statusContinuation) = AsyncStream<Status>.makeStream()
    }

    /// Reaches the host by running `command` and talking to its stdin and
    /// stdout: `ssh studio docker exec -i psyduck psyduck attach`.
    public init(command: String) {
        self.init {
            let stderr = StderrTail()
            let connection = try LineConnection.process(command, stderr: stderr)
            return connection.explaining(stderr)
        }
    }

    // MARK: - Connection

    /// Starts connecting, and keeps the connection up until `shutDown()`.
    public func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    public func shutDown() {
        loop?.cancel()
        loop = nil
        connection?.close()
        statusContinuation.finish()
    }

    /// Drops the wait between attempts: the user asked to try now.
    public func reconnect() {
        guard connection == nil else { return }
        loop?.cancel()
        loop = Task { await run() }
    }

    private func setStatus(_ new: Status) {
        guard status != new else { return }
        status = new
        statusContinuation.yield(new)
    }

    private func run() async {
        var wait: UInt64 = 1
        while !Task.isCancelled {
            setStatus(.connecting)
            var reason = ""
            do {
                let connection = try await connect()
                self.connection = connection
                // Answers have to be read while `hello` waits for its own.
                let reader = Task { await self.read(connection) }
                do {
                    let hello = try await call(.hello)
                    guard hello.version == Wire.version else { throw RemoteError.version(hello.version ?? 0) }
                    setStatus(.connected(hello.host ?? ""))
                    wait = 1
                } catch RemoteError.offline {
                    // The connection went before it answered; `read` knows why.
                } catch {
                    reason = error.localizedDescription
                    connection.close()
                }
                let ended = await reader.value
                if reason.isEmpty { reason = ended }
            } catch {
                reason = error.localizedDescription
            }
            dropConnection(reason)
            if Task.isCancelled { break }
            setStatus(.offline(reason))
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            wait = min(wait * 2, 30)
        }
    }

    /// Hands each message to whoever waits for it. Returns why the
    /// connection ended, once it has, having failed everything still waiting.
    private func read(_ connection: LineConnection) async -> String {
        for await line in connection.lines {
            guard let message = try? Wire.decoder().decode(Wire.Message.self, from: line) else { continue }
            receive(message)
        }
        // A process's last words on stderr can land just after its stdout closes.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let reason = connection.failure ?? "the connection dropped"
        dropConnection(reason)
        return reason
    }

    private func receive(_ message: Wire.Message) {
        if let sub = message.sub {
            if let event = message.event { subscriptions[sub]?.yield(event) }
            if message.ended == true {
                subscriptions[sub]?.finish()
                subscriptions[sub] = nil
            }
            return
        }
        guard let id = message.id, let waiting = pending.removeValue(forKey: id) else { return }
        if let error = message.error {
            waiting.resume(throwing: RemoteError.server(error))
        } else {
            waiting.resume(returning: message.result ?? Wire.Result())
        }
    }

    /// Fails everything that was waiting on the connection that just went.
    private func dropConnection(_ reason: String) {
        connection?.close()
        connection = nil
        for waiting in pending.values { waiting.resume(throwing: RemoteError.offline(reason)) }
        pending = [:]
        for subscription in subscriptions.values { subscription.finish() }
        subscriptions = [:]
    }

    @discardableResult
    private func call(_ method: Wire.Method, _ params: Wire.Params? = nil) async throws -> Wire.Result {
        guard let connection else {
            if case .offline(let reason) = status { throw RemoteError.offline(reason) }
            throw RemoteError.offline("")
        }
        nextID += 1
        let id = nextID
        let data = try Wire.encoder().encode(Wire.Request(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if !connection.send(data) {
                pending[id] = nil
                continuation.resume(throwing: RemoteError.offline("the connection dropped"))
            }
        }
    }

    // MARK: - EngineClient

    public func snapshot() async -> EngineSnapshot {
        (try? await fetchSnapshot()) ?? EngineSnapshot(repos: [], workspaces: [])
    }

    /// The host's repos and workspaces, or an error when it can't be asked:
    /// an offline host's workspaces are unknown, not gone.
    public func fetchSnapshot() async throws -> EngineSnapshot {
        let result = try await call(.snapshot)
        return EngineSnapshot(repos: result.repos ?? [], workspaces: result.workspaces ?? [])
    }

    /// The files a workspace changed, or an error when the host can't be asked.
    public func fetchChangedFiles(_ id: UUID) async throws -> [DiffFile] {
        try await call(.changedFiles, Wire.Params(workspace: id)).files ?? []
    }

    /// Sends a message, or throws when it didn't reach the host.
    public func deliver(_ text: String, to id: UUID) async throws {
        try await call(.send, Wire.Params(workspace: id, text: text))
    }

    public func events(for id: UUID, since: Int) async -> AsyncStream<WorkspaceEvent> {
        let (stream, continuation) = AsyncStream<WorkspaceEvent>.makeStream()
        nextID += 1
        let sub = nextID
        subscriptions[sub] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(sub) }
        }
        do {
            try await call(.events, Wire.Params(workspace: id, since: since, sub: sub))
        } catch {
            subscriptions[sub]?.finish()
            subscriptions[sub] = nil
        }
        return stream
    }

    private func unsubscribe(_ sub: Int) async {
        guard subscriptions.removeValue(forKey: sub) != nil else { return }
        _ = try? await call(.unsubscribe, Wire.Params(sub: sub))
    }

    @discardableResult
    public func addRepo(at path: String) async throws -> Repo {
        guard let repo = try await call(.addRepo, Wire.Params(path: path)).repo else { throw EngineError.unknownRepo }
        return repo
    }

    @discardableResult
    public func cloneRepo(_ url: String) async throws -> Repo {
        guard let repo = try await call(.cloneRepo, Wire.Params(url: url)).repo else { throw EngineError.unknownRepo }
        return repo
    }

    public func removeRepo(_ id: UUID) async {
        _ = try? await call(.removeRepo, Wire.Params(repo: id))
    }

    @discardableResult
    public func newWorkspace(in repoID: UUID, prompt: String?) async throws -> Workspace {
        guard let workspace = try await call(.newWorkspace, Wire.Params(repo: repoID, text: prompt)).workspace else {
            throw EngineError.unknownWorkspace
        }
        return workspace
    }

    public func rename(_ id: UUID, to name: String) async throws {
        do {
            try await call(.rename, Wire.Params(workspace: id, name: name))
        } catch RemoteError.server(let message) {
            throw EngineError.rename(message)
        }
    }

    public func archive(_ id: UUID) async throws {
        try await call(.archive, Wire.Params(workspace: id))
    }

    public func send(_ text: String, to id: UUID) async {
        try? await deliver(text, to: id)
    }

    public func stop(_ id: UUID) async {
        _ = try? await call(.stop, Wire.Params(workspace: id))
    }

    public func changedFiles(_ id: UUID) async -> [DiffFile] {
        (try? await fetchChangedFiles(id)) ?? []
    }

    public func diff(of file: DiffFile, in id: UUID) async throws -> String {
        try await call(.diff, Wire.Params(workspace: id, file: file)).diff ?? ""
    }

    public func branchState(_ id: UUID, network: Bool) async -> BranchState? {
        try? await call(.branchState, Wire.Params(workspace: id, network: network)).branch
    }

    public func perform(_ action: PrimaryAction, on id: UUID) async {
        _ = try? await call(.perform, Wire.Params(workspace: id, action: action))
    }

    public func discard(_ id: UUID) async {
        _ = try? await call(.discard, Wire.Params(workspace: id))
    }
}
