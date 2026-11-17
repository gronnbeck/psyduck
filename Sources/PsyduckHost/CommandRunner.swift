import Foundation

/// One external command: `aws …`, `ssh …`, `git …`.
public struct Command: Equatable {
    public var executable: String
    public var arguments: [String]
    /// Interactive commands inherit the terminal (for `ssh -t` logins).
    /// Their output isn't captured.
    public var interactive: Bool

    public init(_ executable: String, _ arguments: [String], interactive: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.interactive = interactive
    }

    /// The command as you'd type it in a shell.
    public var line: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    /// Quotes one word for a POSIX shell, only when it needs it.
    public static func shellQuote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@%+")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct CommandResult: Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var ok: Bool { status == 0 }

    /// Trimmed stdout, or nil when it's empty or the aws CLI's `None`
    /// (what `--output text` prints for a null query result).
    public var value: String? {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "None" ? nil : text
    }
}

/// Runs commands. The bootstrapper only talks to AWS and the host through
/// this, so tests can fake it and `--dry-run` can print instead of run.
public protocol CommandRunner {
    /// True when nothing is really run. Lookups then come back empty and
    /// the bootstrapper fills in placeholders like `<instance-id>`.
    var isDryRun: Bool { get }
    func run(_ command: Command) throws -> CommandResult
}

/// Runs commands for real, finding executables on PATH.
public struct ProcessRunner: CommandRunner {
    public let isDryRun = false

    public init() {}

    public func run(_ command: Command) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command.executable] + command.arguments

        if command.interactive {
            // Inherits stdin, stdout and stderr, so prompts reach the user.
            try process.run()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus)
        }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain both pipes at once: a full stderr pipe would otherwise
        // block the child while we wait on stdout.
        let outData = Buffer(), errData = Buffer()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { outData.set(out.fileHandleForReading.readDataToEndOfFile()) }
        DispatchQueue.global().async(group: group) { errData.set(err.fileHandleForReading.readDataToEndOfFile()) }
        group.wait()
        process.waitUntilExit()

        return CommandResult(status: process.terminationStatus,
                             stdout: String(decoding: outData.data, as: UTF8.self),
                             stderr: String(decoding: errData.data, as: UTF8.self))
    }
}

/// One pipe's output, handed from the thread that read it.
private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data { lock.withLock { storage } }
    func set(_ data: Data) { lock.withLock { storage = data } }
}

/// Prints each command and runs nothing. Every command "succeeds" with no
/// output.
public final class DryRunRunner: CommandRunner {
    public let isDryRun = true
    public private(set) var commands: [Command] = []
    private let print: (String) -> Void

    public init(print: @escaping (String) -> Void = { Swift.print($0) }) {
        self.print = print
    }

    public func run(_ command: Command) throws -> CommandResult {
        commands.append(command)
        print("$ " + command.line)
        return CommandResult()
    }
}

public enum HostError: Error, CustomStringConvertible, Equatable {
    case commandFailed(String, String)
    case invalid(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .commandFailed(let line, let detail):
            let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Command failed: \(line)" : "Command failed: \(line)\n\(detail)"
        case .invalid(let message), .notFound(let message):
            return message
        }
    }
}

extension CommandRunner {
    /// Runs a command and throws if it exits non-zero.
    @discardableResult
    public func check(_ command: Command) throws -> CommandResult {
        let result = try run(command)
        guard result.ok else { throw HostError.commandFailed(command.line, result.stderr) }
        return result
    }
}
