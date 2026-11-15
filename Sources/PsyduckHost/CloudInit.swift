import Foundation

/// Renders the first-boot script passed to the instance as user data.
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
            "export DEBIAN_FRONTEND=noninteractive",
            "",
            "# 1. Packages. gh comes from GitHub's own apt repository.",
            "apt-get update",
            "apt-get install -y git build-essential curl unzip jq ca-certificates",
            "install -d -m 755 /etc/apt/keyrings",
            "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg",
            "chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg",
            #"echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list"#,
            "apt-get update",
            "apt-get install -y gh",
            "",
            "# 2. Directories psyduck uses.",
            "sudo -u \(user) -H mkdir -p /home/\(user)/psyduck/repos /home/\(user)/psyduck/workspaces /home/\(user)/.local/bin",
            "sudo -u \(user) -H install -d -m 700 /home/\(user)/.config/psyduck",
            "",
            "# 3. claude, with the native installer (lands in ~/.local/bin).",
            "sudo -u \(user) -H bash -c 'curl -fsSL https://claude.ai/install.sh | bash'",
            "",
            "# 4. Let the user's services run with nobody logged in.",
            "loginctl enable-linger \(user)",
        ]
        if installPsyduck {
            lines += [
                "",
                "# 5. psyduck and psyduckd, checked against the published checksum.",
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
