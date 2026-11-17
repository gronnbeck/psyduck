import ArgumentParser
import Foundation
import PsyduckHost

struct Psyduck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "psyduck",
        abstract: "The psyduck command line.",
        subcommands: [Host.self])
}

struct Host: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up and manage EC2 machines that run psyduck sessions.",
        discussion: "Uses your aws CLI profile and ssh. See docs/EC2.md.",
        subcommands: [Create.self, List.self, SSH.self, Stop.self, Start.self,
                      Destroy.self, Login.self, AllowIP.self])
}

/// Flags every `host` command takes.
struct Common: ParsableArguments {
    @Option(help: "The aws CLI profile to use.")
    var profile: String?

    @Option(help: "The AWS region. Defaults to the host's own, then the profile's.")
    var region: String?

    @Flag(name: .customLong("dry-run"), help: "Print the aws and ssh commands without running them.")
    var dryRun = false

    func bootstrapper(key: String? = nil) -> Bootstrapper {
        Bootstrapper(runner: dryRun ? DryRunRunner() : ProcessRunner(),
                     env: .standard(key: key))
    }
}

/// Runs a command body, printing psyduck's own errors without the Swift
/// type name in front.
func report(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as HostError {
        FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
        throw ExitCode.failure
    }
}

extension AccessMode: ExpressibleByArgument {}
extension Architecture: ExpressibleByArgument {}

extension Host {
    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Provision a host, set it up, log in, and register it.",
            discussion: "Safe to run again: it continues from where a failed run stopped.")

        @Argument(help: "A short name, e.g. dev. Lowercase letters, digits and hyphens.")
        var name: String

        @Option(help: "The instance type.")
        var type = "t4g.large"

        @Option(help: "Root disk size in GB.")
        var disk = 50

        @Option(help: "CPU architecture. Must match the instance type.")
        var arch: Architecture = .arm64

        @Option(help: "How to reach the host: ssm (no open ports) or ssh-ip (port 22, your IP only).")
        var access: AccessMode = .ssm

        @Option(help: "The SSH public key to install. Defaults to ~/.ssh/id_ed25519.pub.")
        var key: String?

        @Flag(name: .customLong("no-login"), help: "Skip the claude and GitHub logins.")
        var noLogin = false

        @OptionGroup var common: Common

        func run() throws {
            var options = Bootstrapper.CreateOptions(name: name)
            options.profile = common.profile
            options.region = common.region
            options.type = type
            options.diskGB = disk
            options.arch = arch
            options.access = access
            options.login = !noLogin
            try report { try common.bootstrapper(key: key).create(options) }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List psyduck hosts in the region.")
        @OptionGroup var common: Common

        func run() throws {
            try report { try common.bootstrapper().list(profile: common.profile, region: common.region) }
        }
    }

    struct SSH: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ssh", abstract: "Open a shell on a host.")
        @Argument var name: String
        @OptionGroup var common: Common

        func run() throws {
            var status: Int32 = 0
            try report { status = try common.bootstrapper().ssh(name) }
            if status != 0 { throw ExitCode(status) }
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a host. Its disk, and so its workspaces, are kept.")
        @Argument var name: String
        @OptionGroup var common: Common

        func run() throws {
            try report { try common.bootstrapper().stop(name, profile: common.profile, region: common.region) }
        }
    }

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start a stopped host.")
        @Argument var name: String
        @OptionGroup var common: Common

        func run() throws {
            try report { try common.bootstrapper().start(name, profile: common.profile, region: common.region) }
        }
    }

    struct Destroy: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Terminate a host and delete its security group and ssh entry.")
        @Argument var name: String
        @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
        var yes = false
        @OptionGroup var common: Common

        func run() throws {
            try report {
                try common.bootstrapper().destroy(name, profile: common.profile, region: common.region,
                                                  assumeYes: yes)
            }
        }
    }

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Redo the claude and GitHub logins on a host.")
        @Argument var name: String
        @OptionGroup var common: Common

        func run() throws {
            try report { try common.bootstrapper().login(name) }
        }
    }

    struct AllowIP: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "allow-ip",
            abstract: "For --access ssh-ip hosts: open port 22 to your current IP instead of the old one.")
        @Argument var name: String
        @OptionGroup var common: Common

        func run() throws {
            try report { try common.bootstrapper().allowIP(name, profile: common.profile, region: common.region) }
        }
    }
}

Psyduck.main()
