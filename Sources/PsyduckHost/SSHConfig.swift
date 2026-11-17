import Foundation

/// How the Mac reaches the host.
public enum AccessMode: String, Codable, CaseIterable {
    /// SSH through Session Manager. No inbound ports. The default.
    case ssm
    /// Port 22, open only to the caller's public IP.
    case sshIP = "ssh-ip"
}

/// One host's entry in `~/.ssh/config`, and the editing that keeps psyduck
/// to its own entries. Each entry sits between two marker comments, so it
/// can be updated or removed without touching anything else in the file.
public struct SSHConfigEntry: Equatable {
    public var host: String
    /// The instance id (ssm) or the public IP (ssh-ip).
    public var hostName: String
    public var user: String
    /// The private key, e.g. `~/.ssh/id_ed25519`.
    public var identityFile: String
    public var access: AccessMode
    public var region: String?
    public var profile: String?

    public init(host: String, hostName: String, user: String = "ubuntu", identityFile: String,
                access: AccessMode, region: String? = nil, profile: String? = nil) {
        self.host = host
        self.hostName = hostName
        self.user = user
        self.identityFile = identityFile
        self.access = access
        self.region = region
        self.profile = profile
    }

    /// The name you `ssh` to.
    public static func alias(_ host: String) -> String { "psyduck-\(host)" }

    static func beginMarker(_ host: String) -> String { "# psyduck: \(host) (managed by `psyduck host`)" }
    static func endMarker(_ host: String) -> String { "# psyduck: end \(host)" }

    /// The entry with its markers, without a trailing newline.
    public func render() -> String {
        var lines = [
            Self.beginMarker(host),
            "Host \(Self.alias(host))",
            "  HostName \(hostName)",
            "  User \(user)",
            "  IdentityFile \(identityFile)",
            "  IdentitiesOnly yes",
        ]
        if access == .ssm {
            var proxy = "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p"
            if let region { proxy += " --region \(region)" }
            if let profile { proxy += " --profile \(profile)" }
            lines.append("  ProxyCommand \(proxy)")
        }
        lines.append(Self.endMarker(host))
        return lines.joined(separator: "\n")
    }
}

public enum SSHConfig {
    /// `config` with this host's entry added, or replaced in place if it's
    /// already there. Everything else is left byte for byte.
    public static func upserting(_ entry: SSHConfigEntry, in config: String) -> String {
        var lines = split(config)
        let block = entry.render().components(separatedBy: "\n")
        if let range = blockRange(for: entry.host, in: lines) {
            lines.replaceSubrange(range, with: block)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines += block
        }
        return join(lines)
    }

    /// `config` without this host's entry. Unchanged if there is none.
    public static func removing(host: String, from config: String) -> String {
        var lines = split(config)
        guard let range = blockRange(for: host, in: lines) else { return config }
        lines.removeSubrange(range)
        // Drop the blank line that separated the entry from what came before.
        let before = range.lowerBound - 1
        if before >= 0, lines[before].isEmpty, before == lines.count - 1 || lines[before + 1].isEmpty {
            lines.remove(at: before)
        }
        return join(lines)
    }

    /// The names of the hosts psyduck has entries for.
    public static func hosts(in config: String) -> [String] {
        let lines = split(config)
        return lines.compactMap { line in
            guard line.hasPrefix("# psyduck: "), !line.hasPrefix("# psyduck: end "),
                  let name = line.dropFirst("# psyduck: ".count).split(separator: " ").first else { return nil }
            return blockRange(for: String(name), in: lines) == nil ? nil : String(name)
        }
    }

    /// From the begin marker through the end marker, if both are present.
    private static func blockRange(for host: String, in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(of: SSHConfigEntry.beginMarker(host)),
              let end = lines[start...].firstIndex(of: SSHConfigEntry.endMarker(host)) else { return nil }
        return start..<(end + 1)
    }

    /// Lines, without the empty element a trailing newline would leave.
    private static func split(_ config: String) -> [String] {
        var lines = config.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func join(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
