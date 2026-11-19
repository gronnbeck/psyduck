import Foundation
import PsyduckCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// psyduck, on a host: runs the engine for clients on other machines.
//
//   psyduck serve     run the engine and listen on a unix socket
//   psyduck attach    join stdin and stdout to that socket; what a client's
//                     ssh command runs: ssh host psyduck attach
//   psyduck status    what the engine on this machine has

let environment = ProcessInfo.processInfo.environment

func setting(_ name: String) -> String? {
    environment[name].flatMap { $0.isEmpty ? nil : $0 }
}

/// `$PSYDUCK_SOCKET`, or `~/.psyduck/psyduck.sock`.
let socketPath = setting("PSYDUCK_SOCKET") ?? Shell.home + "/.psyduck/psyduck.sock"
/// `$PSYDUCK_DATA`, or `$XDG_DATA_HOME/psyduck`, or `~/.local/share/psyduck`.
let dataDirectory = setting("PSYDUCK_DATA")
    ?? (setting("XDG_DATA_HOME") ?? Shell.home + "/.local/share") + "/psyduck"
/// `$PSYDUCK_CONFIG`, or `$XDG_CONFIG_HOME/psyduck/config.json`, or `~/.config/psyduck/config.json`.
let configPath = setting("PSYDUCK_CONFIG")
    ?? (setting("XDG_CONFIG_HOME") ?? Shell.home + "/.config") + "/psyduck/config.json"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("psyduck: \(message)\n".utf8))
    exit(1)
}

let usage = """
psyduck, the host side. Runs claude in worktrees for clients on other machines.

  psyduck serve     run the engine; listens on \(socketPath)
  psyduck attach    join stdin and stdout to a running `psyduck serve`
  psyduck status    list the repos and workspaces on this machine

Settings (all optional):
  \(configPath)
      {"model": "", "permissionMode": "bypassPermissions",
       "workspacesRoot": "~/psyduck/workspaces", "reposRoot": "~/psyduck/repos",
       "claudePath": "", "gitPath": ""}
  PSYDUCK_SOCKET, PSYDUCK_DATA, PSYDUCK_CONFIG   where the socket, the state and the config file are
"""

func serve() async -> Never {
    let stateURL = URL(fileURLWithPath: dataDirectory).appendingPathComponent("state.json")
    try? FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
    let storage = EngineStorage(stateURL: stateURL)
    let configURL = URL(fileURLWithPath: configPath)
    // Read at the start of each operation, so an edit applies from the next turn.
    let engine = WorkspaceEngine(loaded: storage.load(), storage: storage) { EngineConfig.load(from: configURL) }

    let listener: UnixListener
    do {
        listener = try UnixListener(path: socketPath)
    } catch {
        fail(error.localizedDescription)
    }
    // Kept for as long as the server runs, which is until one of them fires.
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            listener.close()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    let config = EngineConfig.load(from: configURL)
    let claude = (try? config.resolvedClaude()) ?? "not found: install claude, or set claudePath in \(configPath)"
    print("psyduck serving at \(socketPath)")
    print("  state   \(dataDirectory)")
    print("  claude  \(claude)")
    print("  mode    \(config.permissionMode)")
    setvbuf(stdout, nil, _IOLBF, 0)
    fflush(stdout)
    await RemoteServer(engine: engine).serve(listener)
    withExtendedLifetime(signalSources) {}
    exit(0)
}

/// Copies bytes both ways until either side closes.
func attach() -> Never {
    let socket: Int32
    do {
        socket = try LineConnection.connectedSocket(socketPath)
    } catch {
        fail(error.localizedDescription)
    }
    signal(SIGPIPE, SIG_IGN)

    func pump(from source: Int32, to sink: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            var sent = 0
            while sent < count {
                let wrote = buffer[sent..<count].withUnsafeBytes { write(sink, $0.baseAddress, $0.count) }
                if wrote < 0 && errno == EINTR { continue }
                if wrote <= 0 { return }
                sent += wrote
            }
        }
    }

    let outbound = Thread {
        pump(from: STDIN_FILENO, to: socket)
        exit(0)
    }
    outbound.start()
    pump(from: socket, to: STDOUT_FILENO)
    exit(0)
}

func status() async -> Never {
    let remote = RemoteEngine { try LineConnection.connect(unixSocket: socketPath) }
    await remote.start()
    for await status in remote.statuses {
        if case .offline(let reason) = status { fail(reason) }
        if case .connected = status { break }
    }
    let snapshot = await remote.snapshot()
    if snapshot.repos.isEmpty { print("no repos yet") }
    for repo in snapshot.repos {
        print("\(repo.name)  \(repo.path)")
        for workspace in snapshot.workspaces where workspace.repoID == repo.id {
            let cost = workspace.totalCost.map { String(format: "  $%.2f", $0) } ?? ""
            print("  \(workspace.name)  \(workspace.branch)\(cost)")
        }
    }
    exit(0)
}

switch CommandLine.arguments.dropFirst().first {
case "serve": await serve()
case "attach": attach()
case "status": await status()
case nil, "help", "--help", "-h": print(usage)
case let other?: fail("unknown command \(other). Try: psyduck help")
}
