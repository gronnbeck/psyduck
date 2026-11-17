import Foundation

/// `~/.config/psyduck/.env`: settings for psyduck on this machine, as
/// `KEY=VALUE` lines. Every tool psyduck runs (claude, git, gh) gets them in
/// its environment, on top of what psyduck itself was started with. The host
/// setup script (`scripts/bootstrap-host.sh`) saves the claude login here as
/// `CLAUDE_CODE_OAUTH_TOKEN`.
///
/// The file is read each time a tool starts, so an edit applies to the next
/// command without restarting psyduck.
enum EnvFile {
    static let defaultURL = URL(fileURLWithPath: Shell.home).appendingPathComponent(".config/psyduck/.env")

    /// The file's values, or nothing if it isn't there.
    static func load(_ url: URL = defaultURL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    /// Blank lines and `#` comments are skipped, a leading `export ` is
    /// allowed, and one pair of quotes around a value is removed. Nothing is
    /// expanded: `$HOME` stays as written. A later line wins over an earlier
    /// one with the same key.
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard isName(key) else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    private static func isName(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }
}
