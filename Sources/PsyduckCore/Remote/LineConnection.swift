import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum ConnectionError: LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// A two-way stream of lines over file descriptors: a unix socket, or the
/// pipes of a process (`ssh … psyduck attach`). One thread reads; writes are
/// serialized. Lines never contain a newline, which JSON guarantees.
public final class LineConnection: @unchecked Sendable {
    /// Each line received, without its newline. Ends when the other side
    /// hangs up or `close()` is called.
    public let lines: AsyncStream<Data>

    private let readFD: Int32
    private let writeFD: Int32
    private let lock = NSLock()
    private var closed = false
    private let onClose: @Sendable () -> Void
    private var stderr: StderrTail?

    /// Why the other side went away, when it said: the last line a process
    /// printed on stderr (`ssh: Could not resolve hostname …`).
    public var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let line = stderr?.lastLine, !line.isEmpty else { return nil }
        return line
    }

    func explaining(_ stderr: StderrTail) -> LineConnection {
        lock.lock()
        self.stderr = stderr
        lock.unlock()
        return self
    }

    /// Writing to a pipe whose reader has gone raises SIGPIPE, which would
    /// take the whole process down. Ignored once, process-wide; the write
    /// fails with EPIPE instead.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// `readFD` and `writeFD` may be the same descriptor (a socket). Both are
    /// closed when the connection is. `onClose` runs once, after that.
    public init(readFD: Int32, writeFD: Int32, onClose: @escaping @Sendable () -> Void = {}) {
        _ = Self.ignoreSIGPIPE
        self.readFD = readFD
        self.writeFD = writeFD
        self.onClose = onClose
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lines = stream
        let thread = Thread { [weak self] in
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(readFD, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending.subdata(in: pending.startIndex..<newline)
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty { continuation.yield(line) }
                }
            }
            continuation.finish()
            self?.close()
        }
        thread.name = "psyduck.connection"
        thread.start()
    }

    /// Sends one line. Returns false if the connection is gone.
    @discardableResult
    public func send(_ line: Data) -> Bool {
        var bytes = [UInt8](line)
        bytes.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(writeFD, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return false }
            sent += count
        }
        return true
    }

    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        // Wakes the reading thread if it is still blocked.
        shutdown(readFD, Int32(SHUT_RDWR))
        Self.closeFD(readFD)
        if writeFD != readFD { Self.closeFD(writeFD) }
        onClose()
    }

    private static func closeFD(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #elseif canImport(Glibc)
        _ = Glibc.close(fd)
        #elseif canImport(Musl)
        _ = Musl.close(fd)
        #endif
    }

    // MARK: - Unix sockets

    /// `sockaddr_un` for `path`, or nil when the path is too long for one.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = byte }
        }
        return address
    }

    static func streamSocket() -> Int32 {
        #if canImport(Darwin)
        return socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    /// Connects to a unix socket, as `psyduck attach` does.
    public static func connect(unixSocket path: String) throws -> LineConnection {
        let fd = try connectedSocket(path)
        return LineConnection(readFD: fd, writeFD: fd)
    }

    /// A connected unix socket's descriptor.
    public static func connectedSocket(_ path: String) throws -> Int32 {
        guard var address = address(path) else { throw ConnectionError.failed("socket path is too long: \(path)") }
        let fd = streamSocket()
        guard fd >= 0 else { throw ConnectionError.failed("couldn't make a socket") }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #elseif canImport(Glibc)
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #elseif canImport(Musl)
                Musl.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            closeFD(fd)
            throw ConnectionError.failed("psyduck isn't serving at \(path) (\(reason))")
        }
        return fd
    }

    /// Two connections joined to each other, for tests.
    public static func pair() throws -> (LineConnection, LineConnection) {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #else
        let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
        #endif
        guard result == 0 else { throw ConnectionError.failed("couldn't make a socket pair") }
        return (LineConnection(readFD: fds[0], writeFD: fds[0]), LineConnection(readFD: fds[1], writeFD: fds[1]))
    }

    // MARK: - Processes

    /// Runs `command` through the shell and talks to it over its stdin and
    /// stdout: `ssh studio docker exec -i psyduck psyduck attach`. What it
    /// prints on stderr is kept, so a failure can say why.
    public static func process(_ command: String, stderr: StderrTail = StderrTail()) throws -> LineConnection {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = Shell.environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stderr.append(data) }
        }
        do {
            try process.run()
        } catch {
            throw ConnectionError.failed("couldn't run \(command): \(error.localizedDescription)")
        }
        // Our own copies, so Foundation closing its handles doesn't pull the
        // descriptors out from under the reading thread.
        let readFD = dup(output.fileHandleForReading.fileDescriptor)
        let writeFD = dup(input.fileHandleForWriting.fileDescriptor)
        try? output.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        return LineConnection(readFD: readFD, writeFD: writeFD) {
            if process.isRunning { process.terminate() }
        }
    }
}

/// The last thing a process said on stderr, for error messages.
public final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    public init() {}

    func append(_ more: Data) {
        lock.lock()
        data.append(more)
        if data.count > 4096 { data = data.suffix(4096) }
        lock.unlock()
    }

    /// The last non-empty line.
    public var lastLine: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// A unix socket that accepts connections, for `psyduck serve`.
public final class UnixListener: @unchecked Sendable {
    public let path: String
    public let connections: AsyncStream<LineConnection>
    private let fd: Int32

    /// Replaces a socket file left by a server that is no longer running.
    /// Throws if another server is still answering there.
    public init(path: String) throws {
        self.path = path
        if FileManager.default.fileExists(atPath: path) {
            if let existing = try? LineConnection.connectedSocket(path) {
                _ = shutdown(existing, Int32(SHUT_RDWR))
                throw ConnectionError.failed("psyduck is already serving at \(path)")
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        guard var address = LineConnection.address(path) else {
            throw ConnectionError.failed("socket path is too long: \(path)")
        }
        let fd = LineConnection.streamSocket()
        guard fd >= 0 else { throw ConnectionError.failed("couldn't make a socket") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            throw ConnectionError.failed("couldn't listen at \(path): \(String(cString: strerror(errno)))")
        }
        // Only this user may connect: the socket is the whole of the auth.
        chmod(path, 0o600)
        self.fd = fd

        let (stream, continuation) = AsyncStream<LineConnection>.makeStream()
        connections = stream
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                continuation.yield(LineConnection(readFD: client, writeFD: client))
            }
            continuation.finish()
        }
        thread.name = "psyduck.listener"
        thread.start()
    }

    public func close() {
        _ = shutdown(fd, Int32(SHUT_RDWR))
        try? FileManager.default.removeItem(atPath: path)
    }
}
