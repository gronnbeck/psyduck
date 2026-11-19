import Foundation

/// What a client can ask of an engine, wherever it runs. `WorkspaceEngine`
/// is one in this process; `RemoteEngine` is one on another machine, reached
/// over a connection. The Mac app only ever talks to this.
public protocol EngineClient: Sendable {
    func snapshot() async -> EngineSnapshot
    /// The workspace's events after `since`, then every new one as it
    /// happens. Ends when the workspace goes away or the engine is lost.
    func events(for id: UUID, since: Int) async -> AsyncStream<WorkspaceEvent>

    @discardableResult func addRepo(at path: String) async throws -> Repo
    @discardableResult func cloneRepo(_ url: String) async throws -> Repo
    func removeRepo(_ id: UUID) async

    @discardableResult func newWorkspace(in repoID: UUID, prompt: String?) async throws -> Workspace
    func rename(_ id: UUID, to name: String) async throws
    func archive(_ id: UUID) async throws

    func send(_ text: String, to id: UUID) async
    func stop(_ id: UUID) async

    func changedFiles(_ id: UUID) async -> [DiffFile]
    func diff(of file: DiffFile, in id: UUID) async throws -> String
    func branchState(_ id: UUID, network: Bool) async -> BranchState?
    func perform(_ action: PrimaryAction, on id: UUID) async
    func discard(_ id: UUID) async
}

extension EngineClient {
    @discardableResult
    public func newWorkspace(in repoID: UUID) async throws -> Workspace {
        try await newWorkspace(in: repoID, prompt: nil)
    }
}

extension WorkspaceEngine: EngineClient {}
