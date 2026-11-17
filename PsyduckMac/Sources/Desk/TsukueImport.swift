import Foundation

/// Desk used to be its own app, tsukue. The first time psyduck runs, this
/// copies tsukue's reviews, drafts, review history and settings over, so
/// nothing is lost by switching. It copies and never deletes: tsukue keeps
/// working beside psyduck.
enum TsukueImport {
    static let doneKey = "desk.importedTsukue"
    static let files = ["reviews.json", "drafts.json", "review-history.jsonl"]

    /// tsukue's bundle ids, the one matching this build's channel first.
    static func sources(bundleID: String?) -> [String] {
        let edge = "lol.np.tsukue.edge", release = "lol.np.tsukue"
        return (bundleID ?? "").hasSuffix(".edge") ? [edge, release] : [release, edge]
    }

    static func runOnce(defaults: UserDefaults = .standard,
                        bundleID: String? = Bundle.main.bundleIdentifier,
                        appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                        destination: URL = DeskFolder.directory,
                        settings: (String) -> [String: Any]? = { UserDefaults(suiteName: $0)?.persistentDomain(forName: $0) }) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        let fm = FileManager.default

        // Data: from the first tsukue folder that has any, and only into an
        // empty desk folder.
        let hasData = files.contains { fm.fileExists(atPath: destination.appendingPathComponent($0).path) }
        if !hasData, let folder = sources(bundleID: bundleID)
            .map({ appSupport.appendingPathComponent($0, isDirectory: true) })
            .first(where: { folder in files.contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) } }) {
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in files {
                try? fm.copyItem(at: folder.appendingPathComponent(file), to: destination.appendingPathComponent(file))
            }
        }

        // Settings: tsukue's keys, under desk's names, where desk has none yet.
        guard !DeskSettings.Keys.all.contains(where: { defaults.object(forKey: $0) != nil }),
              let old = sources(bundleID: bundleID).lazy.compactMap(settings).first(where: { !$0.isEmpty }) else { return }
        for key in DeskSettings.Keys.all {
            if let value = old[String(key.dropFirst("desk.".count))] { defaults.set(value, forKey: key) }
        }
    }
}
