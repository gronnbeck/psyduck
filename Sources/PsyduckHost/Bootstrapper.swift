import Foundation

/// Everything outside AWS that the bootstrapper touches on this machine.
/// Tests point the paths at a temp directory and replace the closures.
public struct HostEnvironment {
    public var sshConfigPath: String
    public var registryPath: String
    /// The SSH public key imported as the EC2 key pair. The private key is
    /// the same path without `.pub`.
    public var publicKeyPath: String
    /// Names the shared key pair: `psyduck-<localUser>`.
    public var localUser: String
    /// Where the rendered cloud-init script is written for `run-instances`.
    public var tempDirectory: String
    /// Process environment, for `AWS_REGION`.
    public var variables: [String: String]
    public var toolExists: (String) -> Bool
    public var sleep: (TimeInterval) -> Void
    public var print: (String) -> Void
    /// Asks a yes/no question. Used before `destroy`.
    public var confirm: (String) -> Bool

    public static var defaultSSHConfigPath: String { NSHomeDirectory() + "/.ssh/config" }

    /// The real machine: `~/.ssh/config`, `~/.config/psyduck/hosts.json`,
    /// `~/.ssh/id_ed25519.pub` unless `key` is given.
    public static func standard(key: String? = nil) -> HostEnvironment {
        let home = NSHomeDirectory()
        let variables = ProcessInfo.processInfo.environment
        return HostEnvironment(
            sshConfigPath: defaultSSHConfigPath,
            registryPath: home + "/.config/psyduck/hosts.json",
            publicKeyPath: key.map { ($0 as NSString).expandingTildeInPath } ?? home + "/.ssh/id_ed25519.pub",
            localUser: variables["USER"] ?? "user",
            tempDirectory: NSTemporaryDirectory(),
            variables: variables,
            toolExists: { tool in
                (variables["PATH"] ?? "").split(separator: ":").contains {
                    FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)")
                }
            },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            print: { Swift.print($0) },
            confirm: { question in
                Swift.print(question + " [y/N] ", terminator: "")
                return ["y", "yes"].contains((readLine() ?? "").lowercased())
            })
    }

    public init(sshConfigPath: String, registryPath: String, publicKeyPath: String, localUser: String,
                tempDirectory: String, variables: [String: String] = [:],
                toolExists: @escaping (String) -> Bool = { _ in true },
                sleep: @escaping (TimeInterval) -> Void = { _ in },
                print: @escaping (String) -> Void = { _ in },
                confirm: @escaping (String) -> Bool = { _ in true }) {
        self.sshConfigPath = sshConfigPath
        self.registryPath = registryPath
        self.publicKeyPath = publicKeyPath
        self.localUser = localUser
        self.tempDirectory = tempDirectory
        self.variables = variables
        self.toolExists = toolExists
        self.sleep = sleep
        self.print = print
        self.confirm = confirm
    }
}

/// `psyduck host …`: provisions an EC2 instance, sets it up to run psyduck
/// sessions, and stops, starts and destroys it. See docs/EC2.md.
///
/// Every step looks its resource up by name or tag before creating it, so a
/// `create` that failed halfway picks up where it stopped when run again.
public struct Bootstrapper {
    public let runner: CommandRunner
    public let env: HostEnvironment

    public init(runner: CommandRunner, env: HostEnvironment) {
        self.runner = runner
        self.env = env
    }

    public struct CreateOptions {
        public var name: String
        public var profile: String?
        public var region: String?
        public var type = "t4g.large"
        public var diskGB = 50
        public var arch: Architecture = .arm64
        public var access: AccessMode = .ssm
        /// Run the interactive claude and GitHub logins at the end.
        public var login = true
        /// See `CloudInit.installPsyduck`.
        public var installPsyduck = false

        public init(name: String) {
            self.name = name
        }
    }

    /// The Linux user on the host.
    static let remoteUser = "ubuntu"

    private var registry: HostRegistry { HostRegistry(path: env.registryPath) }
    private func say(_ text: String) { env.print(text) }
    private func step(_ text: String) { env.print("==> " + text) }

    // MARK: create

    @discardableResult
    public func create(_ options: CreateOptions) throws -> HostRecord {
        let name = options.name
        try Self.validate(name: name)

        step("Preflight")
        var aws = AWS(profile: options.profile, region: options.region)
        try runner.check(aws.callerIdentity())
        let region = try resolveRegion(aws)
        aws.region = region
        if options.access == .ssm, !env.toolExists("session-manager-plugin") {
            let hint = "The Session Manager plugin isn't installed. Run: brew install --cask session-manager-plugin"
            guard runner.isDryRun else { throw HostError.invalid(hint) }
            say("warning: " + hint)
        }
        guard FileManager.default.fileExists(atPath: env.publicKeyPath) else {
            throw HostError.invalid("No SSH public key at \(env.publicKeyPath). Make one with ssh-keygen -t ed25519, or pass --key.")
        }

        step("Shared setup: key pair and instance role")
        let keyPair = "psyduck-" + Self.sanitized(env.localUser)
        if try runner.check(aws.findKeyPair(keyPair)).value == nil {
            try runner.check(aws.importKeyPair(keyPair, publicKeyPath: env.publicKeyPath))
        }
        try ensureInstanceRole(aws)

        step("Security group")
        let group = try ensureSecurityGroup(aws, host: name)
        if options.access == .sshIP { try allowCurrentIP(aws, group: group) }

        step("Instance")
        let instance = try ensureInstance(aws, options: options, keyPair: keyPair, group: group)
        try runner.check(aws.wait(.running, instance: instance))

        step("Register")
        let record = HostRecord(name: name, instanceID: instance, region: region,
                                profile: options.profile, access: options.access)
        try register(record, aws: aws)

        step("Wait for the host to finish its first boot")
        if options.access == .ssm { try waitForSSM(aws, instance: instance) }
        try waitForCloudInit(host: name)

        if options.login {
            try login(record)
        } else {
            say("Skipped logins. Run: psyduck host login \(name)")
        }

        say("")
        say(runner.isDryRun ? "Dry run: nothing was created or changed."
                            : "Ready: ssh \(SSHConfigEntry.alias(name))")
        return record
    }

    /// Names become tag values, resource names and an ssh alias.
    public static func validate(name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !name.isEmpty, name.count <= 40, name.unicodeScalars.allSatisfy(allowed.contains),
              !name.hasPrefix("-"), !name.hasSuffix("-") else {
            throw HostError.invalid("Host names are lowercase letters, digits and hyphens, e.g. dev-1. Got: \(name)")
        }
    }

    static func sanitized(_ user: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(String.UnicodeScalarView(user.unicodeScalars.filter(allowed.contains)))
        return cleaned.isEmpty ? "user" : cleaned
    }

    /// `--region`, then `AWS_REGION`, then the profile's configured region.
    private func resolveRegion(_ aws: AWS) throws -> String {
        if let region = aws.region { return region }
        for key in ["AWS_REGION", "AWS_DEFAULT_REGION"] {
            if let region = env.variables[key], !region.isEmpty { return region }
        }
        // Exits 1 with no output when nothing is configured.
        if let region = try runner.run(aws.configuredRegion()).value { return region }
        if runner.isDryRun { return "<region>" }
        throw HostError.invalid("No AWS region. Pass --region, or set one on the profile with aws configure.")
    }

    /// What a lookup found, or a placeholder in a dry run, where nothing
    /// was looked up.
    private func required(_ value: String?, placeholder: String, missing: String) throws -> String {
        if let value { return value }
        if runner.isDryRun { return placeholder }
        throw HostError.notFound(missing)
    }

    /// The `psyduck-host` role and instance profile, with the Session
    /// Manager policy and nothing else.
    private func ensureInstanceRole(_ aws: AWS) throws {
        if try lookup(aws.findRole()) == nil {
            try runner.check(aws.createRole())
        }
        try runner.check(aws.attachSSMPolicy())

        let profile = try lookup(aws.findInstanceProfile())
        if profile == nil {
            try runner.check(aws.createInstanceProfile())
        }
        // "psyduck-host<TAB>psyduck-host", or "…<TAB>None" with no role in it.
        let roles = (profile ?? "").split(whereSeparator: \.isWhitespace).dropFirst()
        if roles.first.map({ $0 == "None" }) ?? true {
            try runner.check(aws.addRoleToInstanceProfile())
        }
    }

    /// An IAM `get-…` that fails with NoSuchEntity means "not there yet".
    /// Any other failure is a real one.
    private func lookup(_ command: Command) throws -> String? {
        let result = try runner.run(command)
        if result.ok { return result.value }
        if result.stderr.contains("NoSuchEntity") { return nil }
        throw HostError.commandFailed(command.line, result.stderr)
    }

    private func ensureSecurityGroup(_ aws: AWS, host: String) throws -> String {
        if let group = try runner.check(aws.findSecurityGroup(host: host)).value { return group }
        let vpc = try required(try runner.check(aws.defaultVPC()).value, placeholder: "<vpc-id>",
                               missing: "This region has no default VPC. Create one with: aws ec2 create-default-vpc")
        return try required(try runner.check(aws.createSecurityGroup(host: host, vpc: vpc)).value,
                            placeholder: "<security-group-id>",
                            missing: "create-security-group returned no group id.")
    }

    /// Opens port 22 to this machine's public IP and closes it to any other
    /// address it was open to.
    private func allowCurrentIP(_ aws: AWS, group: String) throws {
        let lookup = Command("curl", ["-fsS", "https://checkip.amazonaws.com"])
        let ip = try required(try runner.check(lookup).value, placeholder: "<your-ip>",
                              missing: "Couldn't find this machine's public IP.")
        let cidr = ip + "/32"
        let open = (try runner.check(aws.sshIngress(group: group)).value ?? "")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        for other in open where other != cidr {
            try runner.check(aws.revokeSSH(group: group, cidr: other))
        }
        if !open.contains(cidr) {
            try runner.check(aws.allowSSH(group: group, cidr: cidr))
        }
        say("Port 22 is open to \(cidr) only.")
    }

    /// The host's instance id: the one already running, the stopped one
    /// started again, or a newly launched one.
    private func ensureInstance(_ aws: AWS, options: CreateOptions, keyPair: String, group: String) throws -> String {
        if let existing = try Instance.parse(try runner.check(aws.findInstance(host: options.name)).stdout).first {
            say("Found \(existing.id) (\(existing.state)).")
            if existing.state == "stopping" {
                try runner.check(aws.wait(.stopped, instance: existing.id))
            }
            if existing.state == "stopped" || existing.state == "stopping" {
                try runner.check(aws.start(instance: existing.id))
            }
            return existing.id
        }

        let ami = try required(try runner.check(aws.ami(arch: options.arch)).value, placeholder: "<ami-id>",
                               missing: "Couldn't find the Ubuntu 24.04 AMI for \(options.arch.rawValue).")
        let script = CloudInit(arch: options.arch, installPsyduck: options.installPsyduck).render()
        var userDataPath = "<user-data.sh>"
        if runner.isDryRun {
            say("Would pass this first-boot script as user data:")
            say(script.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
        } else {
            userDataPath = (env.tempDirectory as NSString).appendingPathComponent("psyduck-\(options.name)-user-data.sh")
            try script.write(toFile: userDataPath, atomically: true, encoding: .utf8)
        }

        let launch = AWS.Launch(host: options.name, ami: ami, type: options.type, diskGB: options.diskGB,
                                keyPair: keyPair, securityGroup: group, userDataPath: userDataPath)
        let command = aws.runInstance(launch)
        // A just-created instance profile takes a few seconds to reach EC2.
        for attempt in 1...8 {
            let result = try runner.run(command)
            if result.ok {
                return try required(result.value, placeholder: "<instance-id>",
                                    missing: "run-instances returned no instance id.")
            }
            guard result.stderr.contains("Invalid IAM Instance Profile"), attempt < 8 else {
                throw HostError.commandFailed(command.line, result.stderr)
            }
            env.sleep(5)
        }
        throw HostError.commandFailed(command.line, "")
    }

    private func waitForSSM(_ aws: AWS, instance: String) throws {
        for _ in 1...60 {
            if try runner.check(aws.ssmPingStatus(instance: instance)).value == "Online" { return }
            if runner.isDryRun { return }
            env.sleep(5)
        }
        throw HostError.invalid("\(instance) never showed up in Session Manager. Check that its subnet has outbound internet.")
    }

    /// Waits until cloud-init has finished the first-boot script.
    private func waitForCloudInit(host: String) throws {
        let command = Command("ssh", sshArguments() + [
            "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15", "-o", "BatchMode=yes",
            SSHConfigEntry.alias(host), "cloud-init status --wait",
        ])
        var last = CommandResult()
        for _ in 1...30 {
            last = try runner.run(command)
            // 0 is done. 2 is done with recoverable errors.
            if last.status == 0 || runner.isDryRun { return }
            if last.status == 2 {
                say("warning: cloud-init finished with warnings. See /var/log/cloud-init-output.log on the host.")
                return
            }
            // 255 is ssh itself failing: sshd isn't up yet. Anything else
            // is cloud-init reporting an error.
            guard last.status == 255 else { break }
            env.sleep(10)
        }
        throw HostError.commandFailed(command.line, last.stderr.isEmpty ? last.stdout : last.stderr)
    }

    // MARK: ssh config and registry

    /// `-F <path>` when the ssh config isn't the default one (tests).
    private func sshArguments() -> [String] {
        env.sshConfigPath == HostEnvironment.defaultSSHConfigPath ? [] : ["-F", env.sshConfigPath]
    }

    private var identityFile: String {
        let path = env.publicKeyPath.hasSuffix(".pub") ? String(env.publicKeyPath.dropLast(4)) : env.publicKeyPath
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Writes the ssh config entry and the registry record.
    private func register(_ record: HostRecord, aws: AWS) throws {
        var hostName = record.instanceID
        if record.access == .sshIP {
            hostName = try required(try runner.check(aws.publicIP(instance: record.instanceID)).value,
                                    placeholder: "<public-ip>",
                                    missing: "\(record.instanceID) has no public IP.")
        }
        let entry = SSHConfigEntry(host: record.name, hostName: hostName, user: Self.remoteUser,
                                   identityFile: identityFile, access: record.access,
                                   region: record.region, profile: record.profile)
        if runner.isDryRun {
            say("Would add to \(env.sshConfigPath):")
            say(entry.render().split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
            say("Would record the host in \(env.registryPath).")
            return
        }
        try editSSHConfig { SSHConfig.upserting(entry, in: $0) }
        try registry.save(record)
    }

    private func editSSHConfig(_ edit: (String) -> String) throws {
        let path = env.sshConfigPath
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: path)
        let current = exists ? try String(contentsOfFile: path, encoding: .utf8) : ""
        let updated = edit(current)
        guard updated != current else { return }
        let mode = (try? manager.attributesOfItem(atPath: path)[.posixPermissions]) ?? NSNumber(value: 0o600)
        let directory = (path as NSString).deletingLastPathComponent
        if !manager.fileExists(atPath: directory) {
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        try updated.write(toFile: path, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    // MARK: login

    /// The interactive logins. Credentials are typed on the host, over SSH.
    /// They never go into user data, tags, or this machine's files.
    public func login(_ name: String) throws {
        guard let record = try registry.find(name) ?? dryRunRecord(name) else {
            throw HostError.notFound("No host named \(name). See: psyduck host list")
        }
        try login(record)
    }

    private func login(_ record: HostRecord) throws {
        let alias = SSHConfigEntry.alias(record.name)

        // First, so the setup script finds an identity and doesn't ask.
        step("git identity")
        for key in ["user.name", "user.email"] {
            // Exits 1 when the key isn't set locally. Then there's nothing to copy.
            guard let value = try runner.run(Command("git", ["config", "--global", key])).value else { continue }
            try runner.check(remote(alias, script: "git config --global \(key) \(Command.shellQuote(value))"))
        }

        // The setup script walks through the claude and GitHub logins on the
        // host and says what is still missing at the end.
        step("claude and GitHub logins")
        try runner.check(remote(alias, script: "\(CloudInit.scriptPath) --login-only", interactive: true))
    }

    /// `ssh <alias> bash -lc '<script>'`. ssh hands the remote shell one
    /// string, so the script is quoted for it here.
    private func remote(_ alias: String, script: String, interactive: Bool = false) -> Command {
        Command("ssh", sshArguments() + (interactive ? ["-t"] : []) + [alias, "bash -lc " + Command.shellQuote(script)],
                interactive: interactive)
    }

    // MARK: list, ssh, stop, start, allow-ip, destroy

    /// The psyduck-managed instances in the region.
    @discardableResult
    public func list(profile: String?, region: String?) throws -> [Instance] {
        let aws = AWS(profile: profile, region: region)
        let instances = try Instance.parse(try runner.check(aws.listInstances()).stdout)
        if instances.isEmpty {
            if !runner.isDryRun { say("No psyduck hosts in this region.") }
            return []
        }
        let rows = [["NAME", "STATE", "TYPE", "INSTANCE", "PUBLIC IP"]] + instances.map {
            [$0.host ?? "-", $0.state, $0.type ?? "-", $0.id, $0.ip ?? "-"]
        }
        let widths = (0..<5).map { column in rows.map { $0[column].count }.max() ?? 0 }
        for row in rows {
            say(zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
        return instances
    }

    /// Opens a shell on the host. Returns ssh's exit status.
    public func ssh(_ name: String) throws -> Int32 {
        try runner.run(Command("ssh", sshArguments() + [SSHConfigEntry.alias(name)], interactive: true)).status
    }

    public func stop(_ name: String, profile: String?, region: String?) throws {
        let (aws, instance, _) = try resolve(name, profile: profile, region: region)
        try runner.check(aws.stop(instance: instance))
        try runner.check(aws.wait(.stopped, instance: instance))
        say("Stopped \(name). Its disk and workspaces are kept.")
    }

    public func start(_ name: String, profile: String?, region: String?) throws {
        let (aws, instance, record) = try resolve(name, profile: profile, region: region)
        try runner.check(aws.start(instance: instance))
        try runner.check(aws.wait(.running, instance: instance))
        // The public IP changes on every start. Only ssh-ip entries point at it.
        if let record, record.access == .sshIP {
            try register(record, aws: aws)
        }
        say("Started \(name).")
    }

    /// For `--access ssh-ip` hosts: moves the port 22 rule to this machine's
    /// current public IP.
    public func allowIP(_ name: String, profile: String?, region: String?) throws {
        let (aws, _, _) = try resolve(name, profile: profile, region: region)
        let group = try required(try runner.check(aws.findSecurityGroup(host: name)).value,
                                 placeholder: "<security-group-id>",
                                 missing: "No security group for \(name).")
        try allowCurrentIP(aws, group: group)
    }

    /// Terminates the instance and removes its security group, ssh entry
    /// and registry record. The shared key pair and role stay.
    public func destroy(_ name: String, profile: String?, region: String?, assumeYes: Bool) throws {
        let record = try registry.find(name)
        let aws = AWS(profile: profile ?? record?.profile, region: region ?? record?.region)
        let found = try Instance.parse(try runner.check(aws.findInstance(host: name)).stdout).first?.id
        let instance = found ?? (runner.isDryRun ? record?.instanceID ?? "<instance-id>" : nil)
        let group = try runner.check(aws.findSecurityGroup(host: name)).value
            ?? (runner.isDryRun ? "<security-group-id>" : nil)

        guard instance != nil || group != nil || record != nil else {
            throw HostError.notFound("No host named \(name). See: psyduck host list")
        }
        if !assumeYes, !runner.isDryRun {
            let what = instance.map { "instance \($0) and its disk" } ?? "what's left of it"
            guard env.confirm("Destroy \(name)? This deletes \(what), including every workspace on it.") else {
                say("Nothing destroyed.")
                return
            }
        }

        if let instance {
            try runner.check(aws.terminate(instance: instance))
            // The security group can't be deleted while the instance uses it.
            try runner.check(aws.wait(.terminated, instance: instance))
        }
        if let group {
            try runner.check(aws.deleteSecurityGroup(group))
        }
        if runner.isDryRun {
            say("Would remove \(SSHConfigEntry.alias(name)) from \(env.sshConfigPath) and \(env.registryPath).")
            return
        }
        try editSSHConfig { SSHConfig.removing(host: name, from: $0) }
        try registry.remove(name)
        say("Destroyed \(name). The shared key pair and the \(AWS.hostRole) role are kept for other hosts.")
    }

    /// The aws settings and instance id for a host: from the registry, or
    /// looked up by tag when this machine has no record of it.
    private func resolve(_ name: String, profile: String?, region: String?) throws -> (AWS, String, HostRecord?) {
        let record = try registry.find(name)
        let aws = AWS(profile: profile ?? record?.profile, region: region ?? record?.region)
        if let record { return (aws, record.instanceID, record) }
        let found = try Instance.parse(try runner.check(aws.findInstance(host: name)).stdout).first?.id
        let instance = try required(found, placeholder: "<instance-id>",
                                    missing: "No host named \(name). See: psyduck host list")
        return (aws, instance, nil)
    }

    private func dryRunRecord(_ name: String) -> HostRecord? {
        runner.isDryRun ? HostRecord(name: name, instanceID: "<instance-id>", region: "<region>", access: .ssm) : nil
    }
}
