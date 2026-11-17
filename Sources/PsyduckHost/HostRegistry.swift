import Foundation

/// A host psyduck knows about, as kept in `~/.config/psyduck/hosts.json`.
public struct HostRecord: Codable, Equatable {
    public var name: String
    public var instanceID: String
    public var region: String
    public var profile: String?
    public var access: AccessMode

    public init(name: String, instanceID: String, region: String, profile: String? = nil, access: AccessMode) {
        self.name = name
        self.instanceID = instanceID
        self.region = region
        self.profile = profile
        self.access = access
    }
}

/// The list of hosts on this machine. The CLI reads region, profile and
/// access mode from here, so `psyduck host stop dev` needs no flags. The
/// Mac app will read the same file for its sidebar (docs/REMOTE.md, phase 3).
public struct HostRegistry {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func load() throws -> [HostRecord] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode([HostRecord].self, from: data)
    }

    public func find(_ name: String) throws -> HostRecord? {
        try load().first { $0.name == name }
    }

    /// Adds the host, or replaces the one with the same name.
    public func save(_ record: HostRecord) throws {
        var all = try load().filter { $0.name != record.name }
        all.append(record)
        try write(all)
    }

    public func remove(_ name: String) throws {
        let all = try load()
        let kept = all.filter { $0.name != name }
        if kept.count != all.count { try write(kept) }
    }

    private func write(_ records: [HostRecord]) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records.sorted { $0.name < $1.name }).write(to: url, options: .atomic)
    }
}
