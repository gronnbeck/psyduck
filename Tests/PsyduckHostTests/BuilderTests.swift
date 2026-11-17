import Foundation
import XCTest
@testable import PsyduckHost

final class AWSCommandTests: XCTestCase {
    let aws = AWS(profile: "work", region: "eu-north-1")

    private func value(after flag: String, in command: Command) -> String? {
        guard let index = command.arguments.firstIndex(of: flag), index + 1 < command.arguments.count else { return nil }
        return command.arguments[index + 1]
    }

    func testEveryCommandCarriesProfileAndRegion() {
        let launch = AWS.Launch(host: "dev", ami: "ami-1", type: "t4g.large", diskGB: 50,
                                keyPair: "psyduck-ken", securityGroup: "sg-1", userDataPath: "/tmp/u.sh")
        let commands = [
            aws.callerIdentity(), aws.configuredRegion(), aws.ami(arch: .arm64),
            aws.findKeyPair("k"), aws.importKeyPair("k", publicKeyPath: "/k.pub"),
            aws.findRole(), aws.createRole(), aws.attachSSMPolicy(),
            aws.findInstanceProfile(), aws.createInstanceProfile(), aws.addRoleToInstanceProfile(),
            aws.defaultVPC(), aws.findSecurityGroup(host: "dev"), aws.createSecurityGroup(host: "dev", vpc: "vpc-1"),
            aws.deleteSecurityGroup("sg-1"), aws.sshIngress(group: "sg-1"),
            aws.allowSSH(group: "sg-1", cidr: "1.2.3.4/32"), aws.revokeSSH(group: "sg-1", cidr: "1.2.3.4/32"),
            aws.findInstance(host: "dev"), aws.listInstances(), aws.runInstance(launch),
            aws.wait(.running, instance: "i-1"), aws.ssmPingStatus(instance: "i-1"), aws.publicIP(instance: "i-1"),
            aws.stop(instance: "i-1"), aws.start(instance: "i-1"), aws.terminate(instance: "i-1"),
        ]
        for command in commands {
            XCTAssertEqual(command.executable, "aws")
            XCTAssertEqual(value(after: "--profile", in: command), "work", command.line)
            XCTAssertEqual(value(after: "--region", in: command), "eu-north-1", command.line)
        }
    }

    func testNoProfileOrRegionMeansNoFlags() {
        let command = AWS().callerIdentity()
        XCTAssertFalse(command.arguments.contains("--profile"))
        XCTAssertFalse(command.arguments.contains("--region"))
    }

    func testAMIComesFromCanonicalsParameter() {
        XCTAssertEqual(value(after: "--name", in: aws.ami(arch: .arm64)),
                       "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id")
        XCTAssertEqual(value(after: "--name", in: aws.ami(arch: .amd64)),
                       "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id")
    }

    func testRunInstance() {
        let launch = AWS.Launch(host: "dev", ami: "ami-1", type: "t4g.large", diskGB: 80,
                                keyPair: "psyduck-ken", securityGroup: "sg-1", userDataPath: "/tmp/u.sh")
        let command = aws.runInstance(launch)

        XCTAssertEqual(Array(command.arguments.prefix(2)), ["ec2", "run-instances"])
        XCTAssertEqual(value(after: "--image-id", in: command), "ami-1")
        XCTAssertEqual(value(after: "--instance-type", in: command), "t4g.large")
        XCTAssertEqual(value(after: "--key-name", in: command), "psyduck-ken")
        XCTAssertEqual(value(after: "--security-group-ids", in: command), "sg-1")
        XCTAssertEqual(value(after: "--iam-instance-profile", in: command), "Name=psyduck-host")
        XCTAssertEqual(value(after: "--user-data", in: command), "file:///tmp/u.sh")
        // IMDSv2 only, one hop.
        XCTAssertEqual(value(after: "--metadata-options", in: command),
                       "HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled")
        // A shutdown on the box stops, never terminates.
        XCTAssertEqual(value(after: "--instance-initiated-shutdown-behavior", in: command), "stop")

        let disk = value(after: "--block-device-mappings", in: command) ?? ""
        let parsed = try? JSONSerialization.jsonObject(with: Data(disk.utf8)) as? [[String: Any]]
        let ebs = parsed?.first?["Ebs"] as? [String: Any]
        XCTAssertEqual(ebs?["VolumeSize"] as? Int, 80)
        XCTAssertEqual(ebs?["VolumeType"] as? String, "gp3")

        XCTAssertTrue(command.arguments.contains(
            "ResourceType=instance,Tags=[{Key=Name,Value=psyduck-dev},{Key=psyduck:managed,Value=true},{Key=psyduck:host,Value=dev}]"))
    }

    func testSecurityGroupIsCreatedWithNoInboundRules() {
        let command = aws.createSecurityGroup(host: "dev", vpc: "vpc-1")
        XCTAssertEqual(value(after: "--group-name", in: command), "psyduck-dev")
        XCTAssertEqual(value(after: "--vpc-id", in: command), "vpc-1")
        XCTAssertFalse(command.line.contains("ingress"))
        XCTAssertFalse(command.line.contains("--port"))
    }

    func testInstanceRoleIsSessionManagerOnly() {
        XCTAssertEqual(value(after: "--policy-arn", in: aws.attachSSMPolicy()),
                       "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore")
        let policy = try? JSONSerialization.jsonObject(with: Data(AWS.assumeRolePolicy.utf8)) as? [String: Any]
        let statement = (policy?["Statement"] as? [[String: Any]])?.first
        XCTAssertEqual((statement?["Principal"] as? [String: String])?["Service"], "ec2.amazonaws.com")
    }

    func testInstancesAreFoundByTag() {
        XCTAssertTrue(aws.findInstance(host: "dev").arguments.contains("Name=tag:psyduck:host,Values=dev"))
        XCTAssertTrue(aws.listInstances().arguments.contains("Name=tag:psyduck:managed,Values=true"))
        // Terminated instances don't count.
        XCTAssertTrue(aws.findInstance(host: "dev").arguments
            .contains("Name=instance-state-name,Values=pending,running,stopping,stopped"))
    }

    func testInstanceParsing() throws {
        let json = #"[{"id":"i-1","state":"running","type":"t4g.large","ip":null,"host":"dev"}]"#
        XCTAssertEqual(try Instance.parse(json), [Instance(id: "i-1", state: "running", type: "t4g.large", host: "dev")])
        XCTAssertEqual(try Instance.parse("[]\n"), [])
        XCTAssertEqual(try Instance.parse(""), [])
    }

    func testResultValueTreatsNoneAsMissing() {
        XCTAssertNil(CommandResult(stdout: "None\n").value)
        XCTAssertNil(CommandResult(stdout: "\n").value)
        XCTAssertEqual(CommandResult(stdout: "sg-1\n").value, "sg-1")
    }

    func testShellQuoting() {
        XCTAssertEqual(Command("aws", ["ec2", "wait", "instance-running"]).line, "aws ec2 wait instance-running")
        XCTAssertEqual(Command.shellQuote("it's here"), #"'it'\''s here'"#)
        XCTAssertEqual(Command.shellQuote(""), "''")
        XCTAssertEqual(Command.shellQuote("a b"), "'a b'")
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testCapturesOutputAndStatus() throws {
        let result = try ProcessRunner().run(Command("sh", ["-c", "echo out; echo err >&2; exit 3"]))
        XCTAssertEqual(result, CommandResult(status: 3, stdout: "out\n", stderr: "err\n"))
        XCTAssertFalse(result.ok)
    }

    func testCheckThrowsWithTheErrorOutput() {
        XCTAssertThrowsError(try ProcessRunner().check(Command("sh", ["-c", "echo nope >&2; exit 1"]))) { error in
            XCTAssertEqual(error as? HostError, .commandFailed("sh -c 'echo nope >&2; exit 1'", "nope\n"))
        }
    }

    func testALotOfOutputOnBothPipesDoesNotDeadlock() throws {
        let script = "i=0; while [ $i -lt 20000 ]; do echo 0123456789012345678901234567890123456789; echo 0123456789012345678901234567890123456789 >&2; i=$((i+1)); done"
        let result = try ProcessRunner().run(Command("sh", ["-c", script]))
        XCTAssertEqual(result.stdout.count, 20000 * 41)
        XCTAssertEqual(result.stderr.count, 20000 * 41)
    }
}

final class CloudInitTests: XCTestCase {
    func testRunsTheSetupScriptWithoutLogins() {
        let script = CloudInit().render()
        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("https://raw.githubusercontent.com/gronnbeck/psyduck/main/scripts/bootstrap-host.sh -o /usr/local/bin/psyduck-bootstrap-host"))
        XCTAssertTrue(script.contains("\n/usr/local/bin/psyduck-bootstrap-host --no-login --user ubuntu\n"))
        // The install steps live in the script, not here.
        XCTAssertFalse(script.contains("apt-get"))
    }

    func testTheScriptURLCanBeChanged() {
        var cloudInit = CloudInit()
        cloudInit.scriptURL = "https://example.com/setup.sh"
        XCTAssertTrue(cloudInit.render().contains("https://example.com/setup.sh -o "))
    }

    func testHoldsNoSecrets() {
        for script in [CloudInit().render(), CloudInit(installPsyduck: true).render()] {
            let lowered = script.lowercased()
            for word in ["token", "password", "secret_access_key", "sk-ant", "ghp_", "github_pat_", "begin openssh"] {
                // The only "secret"-ish word allowed is the comment saying there are none.
                let lines = lowered.split(separator: "\n").filter { !$0.hasPrefix("#") }
                XCTAssertFalse(lines.contains { $0.contains(word) }, "user data mentions \(word)")
            }
        }
    }

    func testPsyduckDownloadIsOffByDefault() {
        XCTAssertFalse(CloudInit().render().contains("install-service"))

        let script = CloudInit(arch: .arm64, installPsyduck: true).render()
        XCTAssertTrue(script.contains("/psyduck/edge/linux/psyduck-linux-aarch64.tar.gz"))
        XCTAssertTrue(script.contains("sha256sum -c psyduck-linux-aarch64.tar.gz.sha256"))
        XCTAssertTrue(script.contains("install-service"))
        XCTAssertTrue(CloudInit(arch: .amd64, installPsyduck: true).render().contains("psyduck-linux-x86_64.tar.gz"))
    }
}

final class SSHConfigTests: XCTestCase {
    private func entry(_ host: String = "dev", hostName: String = "i-0abc", access: AccessMode = .ssm) -> SSHConfigEntry {
        SSHConfigEntry(host: host, hostName: hostName, identityFile: "~/.ssh/id_ed25519",
                       access: access, region: "eu-north-1", profile: "work")
    }

    func testSSMEntry() {
        XCTAssertEqual(entry().render(), """
            # psyduck: dev (managed by `psyduck host`)
            Host psyduck-dev
              HostName i-0abc
              User ubuntu
              IdentityFile ~/.ssh/id_ed25519
              IdentitiesOnly yes
              ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --region eu-north-1 --profile work
            # psyduck: end dev
            """)
    }

    func testSSHIPEntryHasNoProxy() {
        let text = entry(hostName: "203.0.113.9", access: .sshIP).render()
        XCTAssertTrue(text.contains("HostName 203.0.113.9"))
        XCTAssertFalse(text.contains("ProxyCommand"))
    }

    func testProxyOmitsProfileWhenThereIsNone() {
        let text = SSHConfigEntry(host: "dev", hostName: "i-1", identityFile: "k", access: .ssm, region: "us-east-1").render()
        XCTAssertTrue(text.contains("--region us-east-1"))
        XCTAssertFalse(text.contains("--profile"))
    }

    func testAddsToAnEmptyFile() {
        XCTAssertEqual(SSHConfig.upserting(entry(), in: ""), entry().render() + "\n")
    }

    func testAddsAfterExistingContentAndLeavesItAlone() {
        let mine = "Host github.com\n  User git\n\nHost *\n  AddKeysToAgent yes\n"
        let updated = SSHConfig.upserting(entry(), in: mine)
        XCTAssertEqual(updated, mine + "\n" + entry().render() + "\n")
    }

    func testUpdatesInPlace() {
        let before = "Host a\n  User x\n\n" + entry().render() + "\n\nHost z\n  User y\n"
        let updated = SSHConfig.upserting(entry(hostName: "i-0new"), in: before)
        XCTAssertEqual(updated, "Host a\n  User x\n\n" + entry(hostName: "i-0new").render() + "\n\nHost z\n  User y\n")
        XCTAssertEqual(updated.components(separatedBy: "Host psyduck-dev").count, 2, "exactly one entry")
    }

    func testRemovesOnlyItsOwnEntry() {
        let mine = "Host github.com\n  User git\n"
        var config = SSHConfig.upserting(entry("dev"), in: mine)
        config = SSHConfig.upserting(entry("ci"), in: config)
        XCTAssertEqual(SSHConfig.hosts(in: config), ["dev", "ci"])

        config = SSHConfig.removing(host: "dev", from: config)
        XCTAssertEqual(config, mine + "\n" + entry("ci").render() + "\n")

        config = SSHConfig.removing(host: "ci", from: config)
        XCTAssertEqual(config, mine)
    }

    func testRemovingAHostThatIsNotThereChangesNothing() {
        let mine = "Host github.com\n  User git"
        XCTAssertEqual(SSHConfig.removing(host: "dev", from: mine), mine)
    }

    func testAHostNameThatPrefixesAnotherIsNotConfused() {
        var config = SSHConfig.upserting(entry("dev-2"), in: "")
        config = SSHConfig.upserting(entry("dev"), in: config)
        config = SSHConfig.removing(host: "dev", from: config)
        XCTAssertEqual(config, entry("dev-2").render() + "\n")
    }
}

final class HostRegistryTests: XCTestCase {
    func testSaveFindReplaceRemove() throws {
        let sandbox = try Sandbox()
        let registry = sandbox.registry
        XCTAssertEqual(try registry.load(), [])

        let dev = HostRecord(name: "dev", instanceID: "i-1", region: "eu-north-1", profile: "work", access: .ssm)
        try registry.save(dev)
        try registry.save(HostRecord(name: "ci", instanceID: "i-2", region: "us-east-1", access: .sshIP))
        XCTAssertEqual(try registry.find("dev"), dev)
        XCTAssertEqual(try registry.load().map(\.name), ["ci", "dev"])

        var moved = dev
        moved.instanceID = "i-9"
        try registry.save(moved)
        XCTAssertEqual(try registry.find("dev")?.instanceID, "i-9")
        XCTAssertEqual(try registry.load().count, 2)

        try registry.remove("dev")
        XCTAssertNil(try registry.find("dev"))

        let json = try String(contentsOfFile: sandbox.registryPath, encoding: .utf8)
        XCTAssertTrue(json.contains(#""access" : "ssh-ip""#))
    }
}
