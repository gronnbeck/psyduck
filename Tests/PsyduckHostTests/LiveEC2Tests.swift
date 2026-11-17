import Foundation
import XCTest
@testable import PsyduckHost

/// Creates a real EC2 host, checks it, and destroys it. **Billed**, takes
/// several minutes, and needs an aws profile with the permissions in
/// docs/EC2.md plus the Session Manager plugin. Never run in CI.
///
///     PSYDUCK_LIVE_EC2=1 swift test --filter LiveEC2Tests
///
/// `PSYDUCK_LIVE_EC2_PROFILE` and `PSYDUCK_LIVE_EC2_REGION` pick the account
/// and region. It uses its own ssh config and registry in a temp directory,
/// and your `~/.ssh/id_ed25519.pub`.
final class LiveEC2Tests: XCTestCase {
    func testCreateCheckDestroy() throws {
        let variables = ProcessInfo.processInfo.environment
        guard variables["PSYDUCK_LIVE_EC2"] == "1" else {
            throw XCTSkip("Set PSYDUCK_LIVE_EC2=1 to create (and pay for) a real EC2 host.")
        }

        let root = NSTemporaryDirectory() + "psyduck-live-ec2-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        var env = HostEnvironment.standard()
        env.sshConfigPath = root + "/ssh_config"
        env.registryPath = root + "/hosts.json"
        env.tempDirectory = root
        let runner = ProcessRunner()
        let bootstrapper = Bootstrapper(runner: runner, env: env)

        let name = "livetest-" + UUID().uuidString.prefix(6).lowercased()
        var options = Bootstrapper.CreateOptions(name: name)
        options.profile = variables["PSYDUCK_LIVE_EC2_PROFILE"]
        options.region = variables["PSYDUCK_LIVE_EC2_REGION"]
        options.type = "t4g.small"
        options.diskGB = 20
        options.login = false

        // Whatever happens, don't leave an instance running.
        defer {
            try? bootstrapper.destroy(name, profile: options.profile, region: options.region, assumeYes: true)
        }
        let record = try bootstrapper.create(options)

        let ssh = ["-F", env.sshConfigPath, "-o", "BatchMode=yes", SSHConfigEntry.alias(name)]
        let claude = try runner.run(Command("ssh", ssh + ["~/.local/bin/claude --version"]))
        XCTAssertTrue(claude.ok, claude.stderr)
        let gh = try runner.run(Command("ssh", ssh + ["gh --version"]))
        XCTAssertTrue(gh.ok, gh.stderr)
        XCTAssertTrue(gh.stdout.contains("gh version"))

        try bootstrapper.destroy(name, profile: options.profile, region: options.region, assumeYes: true)
        let aws = AWS(profile: options.profile, region: record.region)
        let left = try Instance.parse(try runner.check(aws.findInstance(host: name)).stdout)
        XCTAssertTrue(left.isEmpty, "the instance is still there after destroy")
    }
}
