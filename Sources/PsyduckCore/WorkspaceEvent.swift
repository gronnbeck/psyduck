import Foundation

/// One thing that happened in a workspace. A workspace's history is the list
/// of these, in `seq` order; the chat and the session's state are built from
/// it by `Transcript`. A client that drops off asks for everything after the
/// last `seq` it saw.
public struct WorkspaceEvent: Equatable, Sendable {
    /// 1, 2, 3… per workspace. Live-only events (`delta`, `partial`) carry
    /// the `seq` of the last stored event, so they never advance a client's
    /// position.
    public var seq: Int
    public var at: Date
    public var kind: Kind

    public init(seq: Int, at: Date = Date(), kind: Kind) {
        self.seq = seq
        self.at = at
        self.kind = kind
    }

    public enum Kind: Equatable, Sendable {
        /// The user's message. A turn starts.
        case prompt(String)
        /// A follow-up sent while claude was busy: everything waiting, to be
        /// sent as one message when the turn ends.
        case queued(String)
        /// claude's session id for this turn.
        case sessionStarted(String)
        /// Live only: a token chunk of the reply being written.
        case textDelta(String)
        /// Live only: the whole reply-so-far, for a client that joins mid-reply.
        case partial(String)
        /// A finished text block. Supersedes the deltas before it.
        case text(String)
        case toolUse(id: String, name: String, summary: String)
        case toolResult(id: String, isError: Bool, output: String)
        /// claude's own end-of-turn line.
        case turnResult(isError: Bool, message: String?, durationMs: Int?, costUSD: Double?, sessionID: String?)
        /// The claude process is gone. `partial` is a reply that was still
        /// being written when it stopped.
        case turnEnded(cancelled: Bool, partial: String?)
        /// A line psyduck adds itself: "committed abc123", or a failure.
        case note(String, isError: Bool)
        /// A chat row from before the event log existed.
        case legacy(ChatItem)

        /// Live-only events are sent to connected clients and never stored.
        public var isLiveOnly: Bool {
            switch self {
            case .textDelta, .partial: return true
            default: return false
            }
        }
    }
}

// The wire and on-disk format: one flat JSON object per event, with a `type`.
//   {"seq":3,"at":"2026-11-15T10:00:00Z","type":"tool_use","id":"t1","name":"Bash","summary":"ls"}
extension WorkspaceEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case seq, at, type, text, id, name, summary, isError, output, message
        case durationMs, costUSD, sessionID, cancelled, item
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        at = try c.decode(Date.self, forKey: .at)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "prompt": kind = .prompt(try c.decode(String.self, forKey: .text))
        case "queued": kind = .queued(try c.decode(String.self, forKey: .text))
        case "session": kind = .sessionStarted(try c.decode(String.self, forKey: .sessionID))
        case "delta": kind = .textDelta(try c.decode(String.self, forKey: .text))
        case "partial": kind = .partial(try c.decode(String.self, forKey: .text))
        case "text": kind = .text(try c.decode(String.self, forKey: .text))
        case "tool_use":
            kind = .toolUse(id: try c.decode(String.self, forKey: .id),
                            name: try c.decode(String.self, forKey: .name),
                            summary: try c.decode(String.self, forKey: .summary))
        case "tool_result":
            kind = .toolResult(id: try c.decode(String.self, forKey: .id),
                               isError: try c.decode(Bool.self, forKey: .isError),
                               output: try c.decode(String.self, forKey: .output))
        case "result":
            kind = .turnResult(isError: try c.decode(Bool.self, forKey: .isError),
                               message: try c.decodeIfPresent(String.self, forKey: .message),
                               durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs),
                               costUSD: try c.decodeIfPresent(Double.self, forKey: .costUSD),
                               sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID))
        case "turn_ended":
            kind = .turnEnded(cancelled: try c.decode(Bool.self, forKey: .cancelled),
                              partial: try c.decodeIfPresent(String.self, forKey: .text))
        case "note":
            kind = .note(try c.decode(String.self, forKey: .text), isError: try c.decode(Bool.self, forKey: .isError))
        case "legacy": kind = .legacy(try c.decode(ChatItem.self, forKey: .item))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(at, forKey: .at)
        switch kind {
        case .prompt(let text):
            try c.encode("prompt", forKey: .type)
            try c.encode(text, forKey: .text)
        case .queued(let text):
            try c.encode("queued", forKey: .type)
            try c.encode(text, forKey: .text)
        case .sessionStarted(let id):
            try c.encode("session", forKey: .type)
            try c.encode(id, forKey: .sessionID)
        case .textDelta(let text):
            try c.encode("delta", forKey: .type)
            try c.encode(text, forKey: .text)
        case .partial(let text):
            try c.encode("partial", forKey: .type)
            try c.encode(text, forKey: .text)
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .toolUse(let id, let name, let summary):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(summary, forKey: .summary)
        case .toolResult(let id, let isError, let output):
            try c.encode("tool_result", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(isError, forKey: .isError)
            try c.encode(output, forKey: .output)
        case .turnResult(let isError, let message, let durationMs, let costUSD, let sessionID):
            try c.encode("result", forKey: .type)
            try c.encode(isError, forKey: .isError)
            try c.encodeIfPresent(message, forKey: .message)
            try c.encodeIfPresent(durationMs, forKey: .durationMs)
            try c.encodeIfPresent(costUSD, forKey: .costUSD)
            try c.encodeIfPresent(sessionID, forKey: .sessionID)
        case .turnEnded(let cancelled, let partial):
            try c.encode("turn_ended", forKey: .type)
            try c.encode(cancelled, forKey: .cancelled)
            try c.encodeIfPresent(partial, forKey: .text)
        case .note(let text, let isError):
            try c.encode("note", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(isError, forKey: .isError)
        case .legacy(let item):
            try c.encode("legacy", forKey: .type)
            try c.encode(item, forKey: .item)
        }
    }
}

/// A workspace's events: all in memory, and appended to a JSONL file when
/// there is one. Not thread-safe; the engine owns it.
public struct EventLog {
    public private(set) var events: [WorkspaceEvent]
    public let url: URL?

    public init(events: [WorkspaceEvent] = [], url: URL? = nil) {
        self.events = events
        self.url = url
    }

    public var lastSeq: Int { events.last?.seq ?? 0 }

    /// Stores a new event with the next `seq` and returns it.
    @discardableResult
    public mutating func append(_ kind: WorkspaceEvent.Kind, at: Date = Date()) -> WorkspaceEvent {
        let event = WorkspaceEvent(seq: lastSeq + 1, at: at, kind: kind)
        events.append(event)
        if let url, var line = try? Self.encoder.encode(event) {
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            }
        }
        return event
    }

    public func since(_ seq: Int) -> [WorkspaceEvent] {
        events.filter { $0.seq > seq }
    }

    /// Reads a log file. Lines that don't parse (a write cut short by a
    /// crash) are skipped.
    public static func read(_ url: URL) -> [WorkspaceEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(WorkspaceEvent.self, from: Data($0)) }
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
