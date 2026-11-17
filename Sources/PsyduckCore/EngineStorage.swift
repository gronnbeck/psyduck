import Foundation

/// Where the engine keeps its state: `state.json` (repos and workspaces) and,
/// beside it, `events/<workspace id>.jsonl`. With no `stateURL` nothing
/// touches the disk, which is what tests want.
public struct EngineStorage: Sendable {
    public let stateURL: URL?

    public init(stateURL: URL?) {
        self.stateURL = stateURL
    }

    /// What was on disk, ready to hand to a `WorkspaceEngine`.
    public struct Loaded: Sendable {
        public var repos: [Repo] = []
        public var workspaces: [Workspace] = []
        public var events: [UUID: [WorkspaceEvent]] = [:]

        public init(repos: [Repo] = [], workspaces: [Workspace] = [], events: [UUID: [WorkspaceEvent]] = [:]) {
            self.repos = repos
            self.workspaces = workspaces
            self.events = events
        }
    }

    private struct SavedState: Codable {
        var repos: [Repo]
        var workspaces: [Workspace]
    }

    /// The pre-event-log `state.json`, where each workspace carried its chat.
    private struct LegacyState: Decodable {
        struct LegacyWorkspace: Decodable {
            var id: UUID
            var items: [ChatItem]?
        }
        var workspaces: [LegacyWorkspace]
    }

    public var eventsDirectory: URL? {
        stateURL?.deletingLastPathComponent().appendingPathComponent("events", isDirectory: true)
    }

    public func logURL(for id: UUID) -> URL? {
        eventsDirectory?.appendingPathComponent("\(id.uuidString).jsonl")
    }

    /// Reads everything. Also, once each:
    /// - moves chats out of an old `state.json` into event logs (the old file
    ///   is kept beside it as `state.v1.json`);
    /// - closes a turn that was cut off when psyduck last quit.
    public func load() -> Loaded {
        guard let stateURL, let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return Loaded() }

        var loaded = Loaded(repos: state.repos, workspaces: state.workspaces)
        let legacy = (try? JSONDecoder().decode(LegacyState.self, from: data))?.workspaces ?? []
        var migrated = false

        for workspace in state.workspaces {
            var log = EventLog(events: logURL(for: workspace.id).map(EventLog.read) ?? [], url: logURL(for: workspace.id))
            if log.events.isEmpty,
               let items = legacy.first(where: { $0.id == workspace.id })?.items, !items.isEmpty {
                for item in items { log.append(.legacy(item)) }
                migrated = true
            }
            if Transcript(events: log.events).running {
                log.append(.note("interrupted: psyduck quit while claude was working", isError: false))
                log.append(.turnEnded(cancelled: false, partial: nil))
            }
            loaded.events[workspace.id] = log.events
        }

        if migrated {
            let backup = stateURL.deletingLastPathComponent().appendingPathComponent("state.v1.json")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? data.write(to: backup, options: .atomic)
            }
            save(repos: state.repos, workspaces: state.workspaces)
        }
        return loaded
    }

    public func save(repos: [Repo], workspaces: [Workspace]) {
        guard let stateURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(SavedState(repos: repos, workspaces: workspaces)) {
            try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    /// Archived workspaces, next to `state.json`. Read and written only when
    /// archiving (and, later, restoring), so they cost nothing at runtime.
    /// An archived workspace's event log stays where it was.
    public var archiveURL: URL? {
        stateURL?.deletingLastPathComponent().appendingPathComponent("archive.json")
    }

    public func loadArchive() -> [Workspace] {
        guard let archiveURL, let data = try? Data(contentsOf: archiveURL) else { return [] }
        return (try? JSONDecoder().decode([Workspace].self, from: data)) ?? []
    }

    /// Adds one record to `archive.json`, leaving the others exactly as they
    /// are written (older ones carry their chat inline).
    public func appendToArchive(_ workspace: Workspace) {
        guard let archiveURL, let record = try? JSONEncoder().encode(workspace),
              let added = try? JSONSerialization.jsonObject(with: record) else { return }
        var records: [Any] = []
        if let data = try? Data(contentsOf: archiveURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            records = existing
        }
        records.append(added)
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: archiveURL, options: .atomic)
        }
    }

    public func deleteLog(for id: UUID) {
        if let url = logURL(for: id) { try? FileManager.default.removeItem(at: url) }
    }

    /// `state.json` in the platform's place for app data: Application Support
    /// on macOS (per bundle id, so edge and local builds don't share it),
    /// `~/.local/share/psyduck` (or `$XDG_DATA_HOME/psyduck`) on Linux.
    public static func defaultStateURL(bundleID: String? = Bundle.main.bundleIdentifier) -> URL? {
        let directory: URL
        #if os(macOS)
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        directory = support.appendingPathComponent(bundleID ?? "lol.np.psyduck", isDirectory: true)
        #else
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (Shell.home + "/.local/share")
        directory = URL(fileURLWithPath: data).appendingPathComponent("psyduck", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.json")
    }
}
