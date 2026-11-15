import Foundation

/// What a finished command left behind.
public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var ok: Bool { status == 0 }

    /// The most useful single line to show when it failed.
    public var failureLine: String {
        let text = stderr.isEmpty ? stdout : stderr
        return text.split(separator: "\n").first.map(String.init) ?? "exited with status \(status)"
    }
}

public enum ShellError: LocalizedError {
    case notFound(String)
    case launch(String, Error)

    public var errorDescription: String? {
        switch self {
        case .notFound(let tool): return "can't find \(tool). set its path in settings."
        case .launch(let path, let error): return "couldn't run \(path): \(error.localizedDescription)"
        }
    }
}

/// Runs the command-line tools psyduck is built on (git, claude).
///
/// An app started from Finder inherits launchd's PATH, not the user's shell
/// one, so Homebrew and `~/.local/bin` are missing; a systemd unit on Linux
/// has the same gap. Every child process gets those added, which is what lets
/// `claude` find `gh` when it runs it.
public enum Shell {
    public static let home = FileManager.default.homeDirectoryForCurrentUser.path

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local"]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extra + [current]).joined(separator: ":")
        return env
    }

    /// Where a tool usually lives, in the order worth trying.
    public static func candidates(for tool: String) -> [String] {
        switch tool {
        case "claude":
            return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        default:
            return ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)", "\(home)/.local/bin/\(tool)"]
        }
    }

    /// The configured path if there is one, otherwise the first candidate
    /// that exists.
    public static func resolve(_ tool: String, configured: String) throws -> String {
        let path = (configured as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
        if !path.isEmpty { return path }
        if let found = candidates(for: tool).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        throw ShellError.notFound(tool)
    }

    /// Asks a login shell, which knows the user's real PATH, then falls back
    /// to the usual places.
    public static func detect(_ tool: String) async -> String? {
        #if os(macOS)
        let loginShell = "/bin/zsh"
        #else
        let loginShell = "/bin/sh"
        #endif
        if let result = try? await run(loginShell, ["-lc", "command -v \(tool)"]), result.ok {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") { return path }
        }
        return candidates(for: tool).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs to completion and collects output.
    public static func run(_ path: String, _ arguments: [String], directory: URL? = nil,
                    input: Data? = nil) async throws -> CommandResult {
        let out = DataBox()
        let result = try await stream(path, arguments, directory: directory, input: input) {
            out.append($0)
            out.append(Data([0x0A]))
        }
        return CommandResult(status: result.status, stdout: String(decoding: out.data, as: UTF8.self), stderr: result.stderr)
    }

    /// Runs to completion, handing each line of stdout over as it arrives —
    /// how a chat turn streams while claude is still working.
    public static func stream(_ path: String, _ arguments: [String], directory: URL? = nil,
                       input: Data? = nil,
                       onLine: @escaping (Data) -> Void) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ShellError.notFound(path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let lines = LineBuffer(onLine: onLine)
                let errors = DataBox()
                let group = DispatchGroup()

                process.terminationHandler = { process in
                    // Output can still be in the pipes when the process exits;
                    // wait for both to reach end-of-file before reporting.
                    group.notify(queue: .global()) {
                        continuation.resume(returning: CommandResult(
                            status: process.terminationStatus,
                            stdout: "",
                            stderr: String(decoding: errors.data, as: UTF8.self)))
                    }
                }

                do {
                    // Entered before the launch so the termination handler,
                    // which can run at once, always waits for the readers.
                    group.enter()
                    group.enter()
                    do {
                        try launch(process)
                    } catch {
                        process.terminationHandler = nil
                        group.leave()
                        group.leave()
                        throw error
                    }
                    drain(stdout.fileHandleForReading, into: { lines.append($0) }) {
                        lines.finish()
                        group.leave()
                    }
                    drain(stderr.fileHandleForReading, into: { errors.append($0) }) {
                        group.leave()
                    }
                    if let stdin, let input {
                        // Written then closed, so the child sees end-of-file.
                        try? stdin.fileHandleForWriting.write(contentsOf: input)
                        try? stdin.fileHandleForWriting.close()
                    }
                } catch {
                    continuation.resume(throwing: ShellError.launch(path, error))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Starts the process with no signals blocked.
    ///
    /// A child inherits the signal mask of the thread that spawns it. On
    /// Linux the threads Swift runs tasks on block nearly every signal, so a
    /// child started from one would never see SIGTERM, and stopping a turn
    /// would do nothing. macOS threads don't block them.
    private static func launch(_ process: Process) throws {
        #if os(Linux)
        var none = sigset_t()
        var previous = sigset_t()
        sigemptyset(&none)
        pthread_sigmask(SIG_SETMASK, &none, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        #endif
        try process.run()
    }

    /// Reads a pipe to its end on a thread of its own, then closes it.
    ///
    /// A blocking read, not `readabilityHandler`: that one sits on a dispatch
    /// source, which on Linux can miss the end-of-file when a descriptor
    /// number is reused, and keeps the descriptor open afterwards.
    private static func drain(_ handle: FileHandle, into sink: @escaping (Data) -> Void,
                              then finish: @escaping () -> Void) {
        Thread.detachNewThread {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                sink(chunk)
            }
            finish()
            try? handle.close()
        }
    }
}

/// Splits a byte stream into lines. Called from one pipe's reader thread only.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let onLine: (Data) -> Void

    init(onLine: @escaping (Data) -> Void) { self.onLine = onLine }

    func append(_ chunk: Data) {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            onLine(pending[pending.startIndex..<newline])
            pending = Data(pending[(newline + 1)...])
        }
    }

    func finish() {
        if !pending.isEmpty { onLine(pending) }
        pending = Data()
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data { lock.withLock { storage } }
    func append(_ chunk: Data) { lock.withLock { storage.append(chunk) } }
}
