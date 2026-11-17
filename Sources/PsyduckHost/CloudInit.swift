import Foundation

/// Renders the first-boot script passed to the instance as user data. It
/// downloads and runs `scripts/bootstrap-host.sh`, which does the install;
/// this adds only what is specific to a psyduck-managed host.
///
/// It holds **no secrets**: anyone who can call
/// `ec2:DescribeInstanceAttribute` can read user data back. Logins happen
/// afterwards, over SSH (see `Bootstrapper.login`).
public struct CloudInit: Equatable {
    /// The Linux user psyduck runs as. `ubuntu` on Canonical's AMIs.
    public var user = "ubuntu"
    public var arch: Architecture = .arm64
    /// Download and install `psyduck` and `psyduckd`. Off by default:
    /// psyduckd doesn't ship yet (docs/REMOTE.md, phase 2), so there is
    /// nothing in the bucket to fetch. The file names below are the planned
    /// ones and may change when the release job exists.
    public var installPsyduck = false
    /// Where the host downloads the setup script from.
    public var scriptURL = "https://raw.githubusercontent.com/gronnbeck/psyduck/main/scripts/bootstrap-host.sh"
    /// Where the setup script is kept on the host.
    public static let scriptPath = "/usr/local/bin/psyduck-bootstrap-host"
    public var distBaseURL = "https://nplol-dist.hel1.your-objectstorage.com/psyduck/edge/linux"

    public init(arch: Architecture = .arm64, installPsyduck: Bool = false) {
        self.arch = arch
        self.installPsyduck = installPsyduck
    }

    /// The archive name for this architecture, e.g. `psyduck-linux-aarch64.tar.gz`.
    var archiveName: String {
        "psyduck-linux-\(arch == .arm64 ? "aarch64" : "x86_64").tar.gz"
    }

    public func render() -> String {
        var lines = [
            "#!/bin/bash",
            "# psyduck host bootstrap. Runs once, as root, on first boot.",
            "# No secrets in here: user data can be read back from the EC2 API.",
            "set -euxo pipefail",
            "",
            "# The install is scripts/bootstrap-host.sh from the psyduck repository,",
            "# the same script you can run by hand on any machine. It stays on the",
            "# host so the logins can run it again.",
            "curl -fsSL --retry 5 --retry-delay 3 \(scriptURL) -o \(Self.scriptPath)",
            "chmod 755 \(Self.scriptPath)",
            "\(Self.scriptPath) --no-login --user \(user)",
        ]
        if installPsyduck {
            lines += [
                "",
                "# psyduck and psyduckd, checked against the published checksum.",
                "sudo -u \(user) -H bash -euxo pipefail <<'PSYDUCK'",
                "cd \"$(mktemp -d)\"",
                "curl -fsSLO \(distBaseURL)/\(archiveName)",
                "curl -fsSLO \(distBaseURL)/\(archiveName).sha256",
                "sha256sum -c \(archiveName).sha256",
                "tar -xzf \(archiveName) -C \"$HOME/.local/bin\"",
                "\"$HOME/.local/bin/psyduck\" install-service",
                "PSYDUCK",
            ]
        }
        lines += ["", "echo 'psyduck bootstrap done'", ""]
        return lines.joined(separator: "\n")
    }
}
