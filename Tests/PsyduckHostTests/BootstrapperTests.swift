import Foundation
import XCTest
@testable import PsyduckHost

final class BootstrapperTests: XCTestCase {
    private var sandbox: Sandbox!
    private var runner: FakeRunner!
    private var bootstrapper: Bootstrapper { Bootstrapper(runner: runner, env: sandbox.env) }

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        runner = FakeRunner()
    }

    private func options(_ name: String = "dev", access: AccessMode = .ssm, login: Bool = false) -> Bootstrapper.CreateOptions {
        var options = Bootstrapper.CreateOptions(name: name)
        options.profile = "work"
        options.region = "eu-north-1"
        options.access = access
        options.login = login
        return options
    }

    /// An account with nothing in it yet: every lookup comes back empty,
    /// every create returns an id.
    private func stubEmptyAccount() {
        runner.stub("describe-key-pairs", stdout: "None\n")
        runner.stub("get-role", stderr: "An error occurred (NoSuchEntity) when calling the GetRole operation", status: 254)
        runner.stub("get-instance-profile", stderr: "An error occurred (NoSuchEntity)", status: 254)
        runner.stub("describe-security-groups", "group-name", stdout: "None\n")
        runner.stub("describe-vpcs", stdout: "vpc-1\n")
        runner.stub("create-security-group", stdout: "sg-1\n")
        runner.stub("describe-instances", "tag:psyduck:host", stdout: "[]\n")
        runner.stub("get-parameter", stdout: "ami-1\n")
        runner.stub("run-instances", stdout: "i-0abc\n")
        runner.stub("describe-instance-information", stdout: "Online\n")
    }

    /// An account where a previous `create` already made everything.
    private func stubExistingHost(state: String = "running") {
        runner.stub("describe-key-pairs", stdout: "psyduck-ken\n")
        runner.stub("get-role", stdout: "psyduck-host\n")
        runner.stub("get-instance-profile", stdout: "psyduck-host\tpsyduck-host\n")
        runner.stub("describe-security-groups", "group-name", stdout: "sg-1\n")
        runner.stub("describe-instances", "tag:psyduck:host",
                    stdout: #"[{"id":"i-0abc","state":"\#(state)","type":"t4g.large","ip":"203.0.113.9","host":"dev"}]"#)
        runner.stub("describe-instance-information", stdout: "Online\n")
    }

    // MARK: create

    func testCreateOnAnEmptyAccount() throws {
        stubEmptyAccount()
        let record = try bootstrapper.create(options())

        XCTAssertEqual(record, HostRecord(name: "dev", instanceID: "i-0abc", region: "eu-north-1",
                                          profile: "work", access: .ssm))
        // In order: shared setup, security group, launch, wait.
        let steps = runner.commands.filter { $0.executable == "aws" }.map { $0.arguments.prefix(2).joined(separator: " ") }
        XCTAssertEqual(steps, [
            "sts get-caller-identity",
            "ec2 describe-key-pairs", "ec2 import-key-pair",
            "iam get-role", "iam create-role", "iam attach-role-policy",
            "iam get-instance-profile", "iam create-instance-profile", "iam add-role-to-instance-profile",
            "ec2 describe-security-groups", "ec2 describe-vpcs", "ec2 create-security-group",
            "ec2 describe-instances", "ssm get-parameter", "ec2 run-instances",
            "ec2 wait",
            "ssm describe-instance-information",
        ])
        // No inbound rule was ever added.
        XCTAssertTrue(runner.ran("authorize-security-group-ingress").isEmpty)

        let launch = try XCTUnwrap(runner.ran("run-instances").first)
        XCTAssertTrue(launch.arguments.contains("ami-1"))
        XCTAssertTrue(launch.arguments.contains("sg-1"))
        XCTAssertTrue(launch.arguments.contains("psyduck-ken"))

        // The user data is the cloud-init script, written to a file.
        let userData = try XCTUnwrap(launch.arguments.first { $0.hasPrefix("file://") })
        let script = try String(contentsOfFile: String(userData.dropFirst("file://".count)), encoding: .utf8)
        XCTAssertEqual(script, CloudInit().render())

        // Registered: ssh entry pointing at the instance id, and a record.
        XCTAssertTrue(sandbox.sshConfig.contains("Host psyduck-dev\n  HostName i-0abc\n"))
        XCTAssertTrue(sandbox.sshConfig.contains("ProxyCommand aws ssm start-session"))
        XCTAssertTrue(sandbox.sshConfig.contains("IdentityFile \(sandbox.root)/.ssh/id_ed25519\n"))
        XCTAssertEqual(try sandbox.registry.find("dev"), record)

        // Then cloud-init is awaited over ssh, using the sandbox's config.
        let wait = try XCTUnwrap(runner.ran("cloud-init status --wait").first)
        XCTAssertEqual(Array(wait.arguments.prefix(2)), ["-F", sandbox.sshConfigPath])
        XCTAssertTrue(wait.arguments.contains("psyduck-dev"))
        XCTAssertEqual(sandbox.output.last, "Ready: ssh psyduck-dev")
    }

    func testCreateAgainCreatesNothing() throws {
        stubExistingHost()
        try bootstrapper.create(options())

        let creating = ["import-key-pair", "create-role", "create-instance-profile", "add-role-to-instance-profile",
                        "create-security-group", "run-instances", "start-instances"]
        for verb in creating {
            XCTAssertTrue(runner.ran(verb).isEmpty, "\(verb) ran on a host that already exists")
        }
        XCTAssertEqual(try sandbox.registry.find("dev")?.instanceID, "i-0abc")
    }

    func testCreateStartsAStoppedHost() throws {
        stubExistingHost(state: "stopped")
        try bootstrapper.create(options())
        XCTAssertEqual(runner.ran("start-instances").count, 1)
        XCTAssertTrue(runner.ran("run-instances").isEmpty)
    }

    func testCreateAddsTheRoleToAnEmptyInstanceProfile() throws {
        stubExistingHost()
        runner = FakeRunner()
        runner.stub("get-instance-profile", stdout: "psyduck-host\tNone\n")
        stubExistingHost()
        try bootstrapper.create(options())
        XCTAssertTrue(runner.ran("create-instance-profile").isEmpty)
        XCTAssertEqual(runner.ran("add-role-to-instance-profile").count, 1)
    }

    func testRunInstancesRetriesWhileTheInstanceProfilePropagates() throws {
        let notYet = CommandResult(status: 254, stderr: "InvalidParameterValue: Invalid IAM Instance Profile name")
        runner.stub(["run-instances"], results: [notYet, notYet, CommandResult(stdout: "i-0abc\n")])
        stubEmptyAccount()
        try bootstrapper.create(options())
        XCTAssertEqual(runner.ran("run-instances").count, 3)
        XCTAssertEqual(sandbox.slept, [5, 5])
    }

    func testOtherLaunchFailuresAreNotRetried() throws {
        runner.stub("run-instances", stderr: "UnauthorizedOperation", status: 254)
        stubEmptyAccount()
        XCTAssertThrowsError(try bootstrapper.create(options())) { error in
            XCTAssertTrue("\(error)".contains("UnauthorizedOperation"))
        }
        XCTAssertEqual(runner.ran("run-instances").count, 1)
        XCTAssertEqual(sandbox.sshConfig, "", "nothing is registered when the launch fails")
    }

    func testAnIAMErrorOtherThanNotFoundStops() throws {
        runner.stub("get-role", stderr: "AccessDenied", status: 254)
        stubEmptyAccount()
        XCTAssertThrowsError(try bootstrapper.create(options()))
        XCTAssertTrue(runner.ran("create-role").isEmpty)
    }

    func testCreateWaitsForSSHToComeUp() throws {
        stubEmptyAccount()
        runner.stub(["cloud-init status --wait"], results: [
            CommandResult(status: 255, stderr: "Connection refused"),
            CommandResult(status: 0, stdout: "status: done\n"),
        ])
        try bootstrapper.create(options())
        XCTAssertEqual(runner.ran("cloud-init status --wait").count, 2)
        XCTAssertEqual(sandbox.slept, [10])
    }

    func testACloudInitFailureIsReported() throws {
        stubEmptyAccount()
        runner.stub("cloud-init status --wait", stdout: "status: error\n", status: 1)
        XCTAssertThrowsError(try bootstrapper.create(options())) { error in
            XCTAssertTrue("\(error)".contains("status: error"))
        }
        // Still registered, so `host ssh` and `host destroy` work.
        XCTAssertNotNil(try sandbox.registry.find("dev"))
    }

    func testPreflightFailures() throws {
        stubEmptyAccount()
        sandbox.installedTools = []
        XCTAssertThrowsError(try bootstrapper.create(options())) { error in
            XCTAssertTrue("\(error)".contains("session-manager-plugin"))
        }
        // ssh-ip doesn't need the plugin.
        runner.stub("checkip.amazonaws.com", stdout: "198.51.100.7\n")
        runner.stub("describe-instances", "PublicIpAddress", "--instance-ids", stdout: "203.0.113.9\n")
        XCTAssertNoThrow(try bootstrapper.create(options(access: .sshIP)))

        sandbox.installedTools = ["session-manager-plugin"]
        try FileManager.default.removeItem(atPath: sandbox.publicKeyPath)
        XCTAssertThrowsError(try bootstrapper.create(options())) { error in
            XCTAssertTrue("\(error)".contains("No SSH public key"))
        }
    }

    func testNotLoggedInToAWSStopsBeforeAnythingIsCreated() throws {
        runner.stub("get-caller-identity", stderr: "Unable to locate credentials", status: 253)
        XCTAssertThrowsError(try bootstrapper.create(options()))
        XCTAssertEqual(runner.commands.count, 1)
    }

    func testRegionFallsBackToTheProfile() throws {
        stubEmptyAccount()
        runner.stub("configure", "get", "region", stdout: "us-west-2\n")
        var options = options()
        options.region = nil
        let record = try bootstrapper.create(options)
        XCTAssertEqual(record.region, "us-west-2")
        XCTAssertTrue(sandbox.sshConfig.contains("--region us-west-2"))
        let launch = try XCTUnwrap(runner.ran("run-instances").first)
        XCTAssertTrue(launch.line.contains("--region us-west-2"))
    }

    func testNoRegionAnywhereIsAnError() throws {
        runner.stub("configure", "get", "region", status: 1)
        var options = options()
        options.region = nil
        XCTAssertThrowsError(try bootstrapper.create(options)) { error in
            XCTAssertTrue("\(error)".contains("No AWS region"))
        }
    }

    func testNameValidation() {
        for good in ["dev", "dev-1", "a", "ci2"] {
            XCTAssertNoThrow(try Bootstrapper.validate(name: good))
        }
        for bad in ["", "Dev", "dev box", "-dev", "dev-", "dev_1", "dev;rm", String(repeating: "a", count: 41)] {
            XCTAssertThrowsError(try Bootstrapper.validate(name: bad), bad)
        }
    }

    // MARK: ssh-ip

    func testSSHIPOpensPort22ToTheCallersIPOnly() throws {
        stubEmptyAccount()
        runner.stub("checkip.amazonaws.com", stdout: "198.51.100.7\n")
        runner.stub("describe-instances", "PublicIpAddress", "--instance-ids", stdout: "203.0.113.9\n")
        try bootstrapper.create(options(access: .sshIP))

        let allow = try XCTUnwrap(runner.ran("authorize-security-group-ingress").first)
        XCTAssertTrue(allow.line.contains("--group-id sg-1 --protocol tcp --port 22 --cidr 198.51.100.7/32"))
        XCTAssertTrue(sandbox.sshConfig.contains("HostName 203.0.113.9"))
        XCTAssertFalse(sandbox.sshConfig.contains("ProxyCommand"))
        // Session Manager isn't waited on.
        XCTAssertTrue(runner.ran("describe-instance-information").isEmpty)
    }

    func testAllowIPMovesTheRule() throws {
        try sandbox.registry.save(HostRecord(name: "dev", instanceID: "i-0abc", region: "eu-north-1",
                                             profile: "work", access: .sshIP))
        runner.stub("describe-security-groups", "group-name", stdout: "sg-1\n")
        runner.stub("describe-security-groups", "--group-ids", stdout: "192.0.2.1/32\n")
        runner.stub("checkip.amazonaws.com", stdout: "198.51.100.7\n")
        try bootstrapper.allowIP("dev", profile: nil, region: nil)

        XCTAssertTrue(try XCTUnwrap(runner.ran("revoke-security-group-ingress").first).line.contains("--cidr 192.0.2.1/32"))
        XCTAssertTrue(try XCTUnwrap(runner.ran("authorize-security-group-ingress").first).line.contains("--cidr 198.51.100.7/32"))
        // The registry supplied the profile and region.
        XCTAssertTrue(runner.ran("authorize-security-group-ingress")[0].line.hasSuffix("--profile work --region eu-north-1"))
    }

    func testAllowIPDoesNothingWhenTheRuleIsAlreadyRight() throws {
        runner.stub("describe-instances", stdout: #"[{"id":"i-0abc","state":"running"}]"#)
        runner.stub("describe-security-groups", "group-name", stdout: "sg-1\n")
        runner.stub("describe-security-groups", "--group-ids", stdout: "198.51.100.7/32\n")
        runner.stub("checkip.amazonaws.com", stdout: "198.51.100.7\n")
        try bootstrapper.allowIP("dev", profile: nil, region: nil)
        XCTAssertTrue(runner.ran("revoke-security-group-ingress").isEmpty)
        XCTAssertTrue(runner.ran("authorize-security-group-ingress").isEmpty)
    }

    // MARK: login

    func testLoginIsInteractiveAndCopiesOnlyGitIdentity() throws {
        try sandbox.registry.save(HostRecord(name: "dev", instanceID: "i-0abc", region: "eu-north-1", access: .ssm))
        runner.stub("git", "config", "--global", "user.name", stdout: "Ken O'Duck\n")
        runner.stub("git", "config", "--global", "user.email", stdout: "ken@example.com\n")
        try bootstrapper.login("dev")

        let remote = runner.commands.filter { $0.executable == "ssh" }
        XCTAssertEqual(remote.count, 4)

        // claude and gh log in on the host, on a terminal.
        XCTAssertTrue(remote[0].interactive)
        XCTAssertTrue(remote[0].arguments.contains("-t"))
        XCTAssertTrue(remote[0].line.contains("setup-token"))
        XCTAssertTrue(remote[1].interactive)
        XCTAssertTrue(remote[1].line.contains("gh auth login --hostname github.com --git-protocol https"))
        XCTAssertTrue(remote[1].line.contains("gh auth setup-git"))

        // Only the git identity is copied from this machine.
        XCTAssertEqual(remote[2].arguments.last, #"bash -lc 'git config --global user.name '\''Ken O'\''\'\'''\''Duck'\'''"#)
        XCTAssertTrue(remote[3].line.contains("user.email ken@example.com"))

        // The Mac's GitHub token is never read, and nothing secret is sent.
        XCTAssertTrue(runner.commands.filter { $0.executable == "gh" }.isEmpty)
        XCTAssertFalse(runner.commands.contains { $0.line.contains("auth token") })
        XCTAssertTrue(sandbox.output.contains { $0.contains("fine-grained token") })
    }

    func testLoginSkipsAGitIdentityThatIsNotSet() throws {
        try sandbox.registry.save(HostRecord(name: "dev", instanceID: "i-0abc", region: "eu-north-1", access: .ssm))
        runner.stub("git", "config", "--global", status: 1)
        try bootstrapper.login("dev")
        XCTAssertEqual(runner.commands.filter { $0.executable == "ssh" }.count, 2)
    }

    func testLoginOnAnUnknownHost() {
        XCTAssertThrowsError(try bootstrapper.login("nope")) { error in
            XCTAssertTrue("\(error)".contains("No host named nope"))
        }
    }

    // MARK: list, stop, start, destroy

    func testList() throws {
        runner.stub("describe-instances", stdout: """
            [{"id":"i-1","state":"running","type":"t4g.large","ip":"203.0.113.9","host":"dev"},
             {"id":"i-2","state":"stopped","type":"t4g.small","ip":null,"host":"ci"}]
            """)
        let instances = try bootstrapper.list(profile: "work", region: "eu-north-1")
        XCTAssertEqual(instances.map(\.id), ["i-1", "i-2"])
        XCTAssertEqual(sandbox.output, [
            "NAME  STATE    TYPE       INSTANCE  PUBLIC IP",
            "dev   running  t4g.large  i-1       203.0.113.9",
            "ci    stopped  t4g.small  i-2       -",
        ])
    }

    func testStopUsesTheRegistry() throws {
        try sandbox.registry.save(HostRecord(name: "dev", instanceID: "i-0abc", region: "eu-north-1",
                                             profile: "work", access: .ssm))
        try bootstrapper.stop("dev", profile: nil, region: nil)
        XCTAssertEqual(runner.commands.map(\.line), [
            "aws ec2 stop-instances --instance-ids i-0abc --profile work --region eu-north-1",
            "aws ec2 wait instance-stopped --instance-ids i-0abc --profile work --region eu-north-1",
        ])
    }

    func testStopFindsAnUnregisteredHostByTag() throws {
        runner.stub("describe-instances", stdout: #"[{"id":"i-9","state":"running"}]"#)
        try bootstrapper.stop("dev", profile: nil, region: "us-east-1")
        XCTAssertEqual(runner.ran("stop-instances").first?.line,
                       "aws ec2 stop-instances --instance-ids i-9 --region us-east-1")
    }

    func testStopOnAnUnknownHost() {
        runner.stub("describe-instances", stdout: "[]")
        XCTAssertThrowsError(try bootstrapper.stop("nope", profile: nil, region: nil))
        XCTAssertTrue(runner.ran("stop-instances").isEmpty)
    }

    func testStartRefreshesAnSSHIPEntry() throws {
        let record = HostRecord(name: "dev", instanceID: "i-0abc", region: "eu-north-1", access: .sshIP)
        try sandbox.registry.save(record)
        runner.stub("PublicIpAddress", "--instance-ids", stdout: "203.0.113.50\n")
        try bootstrapper.start("dev", profile: nil, region: nil)
        XCTAssertEqual(runner.ran("start-instances").count, 1)
        XCTAssertEqual(runner.ran("wait", "instance-running").count, 1)
        XCTAssertTrue(sandbox.sshConfig.contains("HostName 203.0.113.50"))
    }

    func testDestroy() throws {
        stubEmptyAccount()
        try bootstrapper.create(options())
        try "Host github.com\n  User git\n".write(toFile: sandbox.sshConfigPath + ".mine", atomically: true, encoding: .utf8)

        runner = FakeRunner()
        stubExistingHost()
        try bootstrapper.destroy("dev", profile: nil, region: nil, assumeYes: true)

        XCTAssertEqual(runner.commands.suffix(3).map { $0.arguments.prefix(3).joined(separator: " ") }, [
            "ec2 terminate-instances --instance-ids",
            "ec2 wait instance-terminated",
            "ec2 delete-security-group --group-id",
        ])
        XCTAssertEqual(sandbox.sshConfig, "")
        XCTAssertNil(try sandbox.registry.find("dev"))
        // The shared pieces stay.
        XCTAssertTrue(runner.ran("delete-key-pair").isEmpty)
        XCTAssertTrue(runner.ran("delete-role").isEmpty)
    }

    func testDestroyAsksFirst() throws {
        try sandbox.registry.save(HostRecord(name: "dev", instanceID: "i-0abc", region: "eu-north-1", access: .ssm))
        stubExistingHost()
        sandbox.confirmAnswer = false
        try bootstrapper.destroy("dev", profile: nil, region: nil, assumeYes: false)
        XCTAssertTrue(runner.ran("terminate-instances").isEmpty)
        XCTAssertTrue(runner.ran("delete-security-group").isEmpty)
        XCTAssertNotNil(try sandbox.registry.find("dev"))
    }

    func testDestroyOnAnUnknownHost() {
        runner.stub("describe-instances", stdout: "[]")
        runner.stub("describe-security-groups", stdout: "None")
        XCTAssertThrowsError(try bootstrapper.destroy("nope", profile: nil, region: nil, assumeYes: true))
    }

    // MARK: dry run

    func testDryRunPrintsEveryStepAndChangesNothing() throws {
        var printed: [String] = []
        let dry = DryRunRunner { printed.append($0) }
        var options = options(login: true)
        options.region = nil
        try Bootstrapper(runner: dry, env: sandbox.env).create(options)

        let verbs = dry.commands.filter { $0.executable == "aws" }.map { $0.arguments[1] }
        for verb in ["get-caller-identity", "import-key-pair", "create-role", "attach-role-policy",
                     "create-instance-profile", "add-role-to-instance-profile", "create-security-group",
                     "get-parameter", "run-instances", "wait", "describe-instance-information"] {
            XCTAssertTrue(verbs.contains(verb), "dry run skipped \(verb)")
        }
        // Ids that only exist after a real run are placeholders.
        let launch = try XCTUnwrap(dry.commands.first { $0.arguments.contains("run-instances") })
        XCTAssertTrue(launch.arguments.contains("<ami-id>"))
        XCTAssertTrue(launch.arguments.contains("<security-group-id>"))
        XCTAssertTrue(launch.arguments.contains("file://<user-data.sh>"))
        XCTAssertTrue(dry.commands.contains { $0.arguments.contains("<instance-id>") })
        XCTAssertEqual(printed.count, dry.commands.count)
        XCTAssertTrue(printed.allSatisfy { $0.hasPrefix("$ ") })

        // The logins are shown too.
        XCTAssertTrue(dry.commands.contains { $0.line.contains("setup-token") })
        // Nothing was written.
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.sshConfigPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.registryPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.root), [".ssh"])
        XCTAssertTrue(sandbox.output.contains { $0.contains("Would add to") })
        XCTAssertTrue(sandbox.output.contains { $0.contains("#!/bin/bash") })
    }

    func testDryRunDestroy() throws {
        let dry = DryRunRunner { _ in }
        try Bootstrapper(runner: dry, env: sandbox.env).destroy("dev", profile: nil, region: "eu-north-1", assumeYes: false)
        XCTAssertTrue(dry.commands.contains { $0.line.contains("terminate-instances --instance-ids '<instance-id>'") })
        XCTAssertTrue(dry.commands.contains { $0.line.contains("delete-security-group --group-id '<security-group-id>'") })
    }
}
