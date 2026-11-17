import Foundation
import XCTest
@testable import PsyduckHost

/// A runner that answers from stubs and records every command. Commands
/// with no stub succeed with no output.
final class FakeRunner: CommandRunner {
    let isDryRun = false
    private(set) var commands: [Command] = []
    private var stubs: [(tokens: [String], results: [CommandResult])] = []

    /// Answers any command whose executable and arguments include every
    /// token. Given several results, it returns them in turn and then keeps
    /// returning the last.
    func stub(_ tokens: String..., stdout: String = "", stderr: String = "", status: Int32 = 0) {
        stubs.append((tokens, [CommandResult(status: status, stdout: stdout, stderr: stderr)]))
    }

    func stub(_ tokens: [String], results: [CommandResult]) {
        stubs.append((tokens, results))
    }

    func run(_ command: Command) throws -> CommandResult {
        commands.append(command)
        let words = [command.executable] + command.arguments
        guard let index = stubs.firstIndex(where: { stub in stub.tokens.allSatisfy { token in words.contains { $0.contains(token) } } }) else {
            return CommandResult()
        }
        let result = stubs[index].results[0]
        if stubs[index].results.count > 1 { stubs[index].results.removeFirst() }
        return result
    }

    /// The recorded commands whose words include every token.
    func ran(_ tokens: String...) -> [Command] {
        commands.filter { command in
            let words = [command.executable] + command.arguments
            return tokens.allSatisfy { token in words.contains { $0.contains(token) } }
        }
    }
}

/// A scratch home: ssh config, registry and key all live in a temp
/// directory, never the real `~/.ssh` or `~/.config`.
final class Sandbox {
    let root: String
    var output: [String] = []
    var slept: [TimeInterval] = []
    var confirmAnswer = true
    var installedTools: Set<String> = ["session-manager-plugin"]

    init() throws {
        root = NSTemporaryDirectory() + "psyduck-host-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/.ssh", withIntermediateDirectories: true)
        try "ssh-ed25519 AAAATESTKEY test@example\n".write(toFile: publicKeyPath, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    var sshConfigPath: String { root + "/.ssh/config" }
    var registryPath: String { root + "/.config/psyduck/hosts.json" }
    var publicKeyPath: String { root + "/.ssh/id_ed25519.pub" }

    var sshConfig: String { (try? String(contentsOfFile: sshConfigPath, encoding: .utf8)) ?? "" }
    var registry: HostRegistry { HostRegistry(path: registryPath) }

    var env: HostEnvironment {
        HostEnvironment(sshConfigPath: sshConfigPath, registryPath: registryPath,
                        publicKeyPath: publicKeyPath, localUser: "ken", tempDirectory: root,
                        toolExists: { [unowned self] in self.installedTools.contains($0) },
                        sleep: { [unowned self] in self.slept.append($0) },
                        print: { [unowned self] in self.output.append($0) },
                        confirm: { [unowned self] _ in self.confirmAnswer })
    }
}
