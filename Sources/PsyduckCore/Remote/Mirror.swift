import Foundation

/// One file in a workspace, as the host lists it for a client that wants a
/// copy: everything git tracks, plus untracked files git doesn't ignore.
public struct FileEntry: Codable, Hashable, Sendable {
    /// Relative to the worktree.
    public var path: String
    public var size: Int
    /// Seconds since 1970.
    public var modified: Double
    /// Unix permission bits, for the executable bit.
    public var mode: Int
    /// A symlink's target; `size` is then meaningless.
    public var link: String?

    public init(path: String, size: Int, modified: Double, mode: Int, link: String? = nil) {
        self.path = path
        self.size = size
        self.modified = modified
        self.mode = mode
        self.link = link
    }
}

/// One file's bytes. `data` is nil when the file went away after it was listed.
public struct FileContent: Codable, Sendable {
    public var path: String
    public var data: Data?

    public init(path: String, data: Data?) {
        self.path = path
        self.data = data
    }
}

/// What a sync did.
public struct MirrorResult: Equatable, Sendable {
    public var copied = 0
    public var removed = 0
    /// Files left out, and why: too big, or a path that isn't safe to write.
    public var skipped: [String] = []

    public init(copied: Int = 0, removed: Int = 0, skipped: [String] = []) {
        self.copied = copied
        self.removed = removed
        self.skipped = skipped
    }
}

/// Keeps a folder on this machine equal to a workspace on a host. One way:
/// the host's files overwrite the copy. Only files it put there are ever
/// removed, so build products made in the copy are left alone.
public enum WorkspaceMirror {
    /// Files above this are skipped rather than carried through memory.
    public static let largestFile = 100 * 1024 * 1024
    /// Roughly how much is asked for in one call.
    static let batchBytes = 8 * 1024 * 1024
    /// What the last sync wrote, kept in the copy itself.
    static let manifestName = ".psyduck-mirror.json"

    public static func sync(into directory: URL, entries: [FileEntry],
                            fetch: ([String]) async throws -> [FileContent]) async throws -> MirrorResult {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.resolvingSymlinksInPath().path
        var result = MirrorResult()

        var wanted: [FileEntry] = []
        for entry in entries {
            if !isSafe(entry.path) {
                result.skipped.append("\(entry.path): not a path inside the workspace")
            } else if entry.link == nil && entry.size > largestFile {
                result.skipped.append("\(entry.path): larger than \(largestFile / 1024 / 1024) MB")
            } else {
                wanted.append(entry)
            }
        }

        // Remove what an earlier sync wrote and the host no longer has.
        let manifestURL = directory.appendingPathComponent(manifestName)
        let before = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let now = Set(wanted.map(\.path))
        for path in before where !now.contains(path) && isSafe(path) {
            let url = directory.appendingPathComponent(path)
            guard staysInside(root, url) else { continue }
            if (try? files.removeItem(at: url)) != nil { result.removed += 1 }
            removeEmptyParents(of: url, upTo: directory)
        }

        var batch: [FileEntry] = []
        var batchSize = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            let byPath = Dictionary(batch.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            for content in try await fetch(batch.map(\.path)) {
                guard let entry = byPath[content.path], let data = content.data else { continue }
                let url = directory.appendingPathComponent(entry.path)
                guard prepare(url, in: directory, root: root) else {
                    result.skipped.append("\(entry.path): its folder is a link out of the copy")
                    continue
                }
                try data.write(to: url)
                stamp(url, with: entry)
                result.copied += 1
            }
            batch = []
            batchSize = 0
        }

        for entry in wanted {
            let url = directory.appendingPathComponent(entry.path)
            if let target = entry.link {
                if (try? files.destinationOfSymbolicLink(atPath: url.path)) == target { continue }
                guard prepare(url, in: directory, root: root) else {
                    result.skipped.append("\(entry.path): its folder is a link out of the copy")
                    continue
                }
                try files.createSymbolicLink(atPath: url.path, withDestinationPath: target)
                result.copied += 1
                continue
            }
            if isCurrent(url, entry) { continue }
            batch.append(entry)
            batchSize += entry.size
            if batchSize >= batchBytes { try await flush() }
        }
        try await flush()

        if let data = try? JSONEncoder().encode(wanted.map(\.path).sorted()) {
            try? data.write(to: manifestURL, options: .atomic)
        }
        return result
    }

    /// A relative path with no way out of the folder it is joined to.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." } && path != manifestName
    }

    /// The folder `url` sits in, with links followed, is still under `root`.
    private static func staysInside(_ root: String, _ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return parent == root || parent.hasPrefix(root + "/")
    }

    /// Makes the folders for `url` and clears whatever is in its place.
    /// False when a link on the way would put the file outside the copy.
    private static func prepare(_ url: URL, in directory: URL, root: String) -> Bool {
        let files = FileManager.default
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard staysInside(root, url) else { return false }
        // Never write through a link that is where the file should be.
        if (try? files.attributesOfItem(atPath: url.path)) != nil { try? files.removeItem(at: url) }
        return true
    }

    /// The copy already has this file as the host has it: same size and time.
    private static func isCurrent(_ url: URL, _ entry: FileEntry) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date else { return false }
        return size.intValue == entry.size && abs(date.timeIntervalSince1970 - entry.modified) < 1
    }

    private static func stamp(_ url: URL, with entry: FileEntry) {
        try? FileManager.default.setAttributes([
            .modificationDate: Date(timeIntervalSince1970: entry.modified),
            .posixPermissions: NSNumber(value: entry.mode & 0o777),
        ], ofItemAtPath: url.path)
    }

    private static func removeEmptyParents(of url: URL, upTo directory: URL) {
        var parent = url.deletingLastPathComponent()
        while parent.path.count > directory.path.count,
              (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
            parent = parent.deletingLastPathComponent()
        }
    }
}
