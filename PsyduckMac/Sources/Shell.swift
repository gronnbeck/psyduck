import Foundation

/// What a finished command left behind.
struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { status == 0 }

    /// The most useful single line to show when it failed.
    var failureLine: String {
        let text = stderr.isEmpty ? stdout : stderr
        return text.split(separator: "\n").first.map(String.init) ?? "exited with status \(status)"
    }
}

enum ShellError: LocalizedError {
    case notFound(String)
    case launch(String, Error)

    var errorDescription: String? {
        switch self {
        case .notFound(let tool): return "can't find \(tool). set its path in settings."
        case .launch(let path, let error): return "couldn't run \(path): \(error.localizedDescription)"
        }
    }
}

/// Runs the command-line tools psyduck is built on (git, claude).
///
/// An app started from Finder inherits launchd's PATH, not the user's shell
/// one, so Homebrew and `~/.local/bin` are missing. Every child process gets
/// those added, which is what lets `claude` find `gh` when it runs it.
enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local"]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extra + [current]).joined(separator: ":")
        return env
    }

    /// Where a tool usually lives, in the order worth trying.
    static func candidates(for tool: String) -> [String] {
        switch tool {
        case "claude":
            return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        default:
            return ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)", "\(home)/.local/bin/\(tool)"]
        }
    }

    /// The configured path if there is one, otherwise the first candidate
    /// that exists.
    static func resolve(_ tool: String, configured: String) throws -> String {
        let path = (configured as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
        if !path.isEmpty { return path }
        if let found = candidates(for: tool).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        throw ShellError.notFound(tool)
    }

    /// Asks a login shell, which knows the user's real PATH, then falls back
    /// to the usual places.
    static func detect(_ tool: String) async -> String? {
        if let result = try? await run("/bin/zsh", ["-lc", "command -v \(tool)"]), result.ok {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") { return path }
        }
        return candidates(for: tool).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs to completion and collects output.
    static func run(_ path: String, _ arguments: [String], directory: URL? = nil,
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
    static func stream(_ path: String, _ arguments: [String], directory: URL? = nil,
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

                group.enter()
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        lines.finish()
                        group.leave()
                    } else {
                        lines.append(chunk)
                    }
                }
                group.enter()
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        group.leave()
                    } else {
                        errors.append(chunk)
                    }
                }

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
                    try process.run()
                    if let stdin, let input {
                        // Written then closed, so the child sees end-of-file.
                        try? stdin.fileHandleForWriting.write(contentsOf: input)
                        try? stdin.fileHandleForWriting.close()
                    }
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ShellError.launch(path, error))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Splits a byte stream into lines. Called from one pipe's handler queue only.
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
