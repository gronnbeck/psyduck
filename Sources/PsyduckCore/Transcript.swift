import Foundation

/// A workspace's session, built from its events: the chat rows, whether
/// claude is working, the reply being written, and what's queued. The engine
/// keeps one per workspace and so does every client; feeding both the same
/// events gives both the same picture.
public struct Transcript: Equatable, Sendable {
    public private(set) var items: [ChatItem] = []
    /// A claude turn is in flight.
    public private(set) var running = false
    /// The reply being written right now, before claude finishes the block.
    public private(set) var streaming = ""
    /// When the running turn started, for the composer's clock.
    public private(set) var turnStarted: Date?
    /// A follow-up typed while claude was busy, sent when the turn ends.
    public private(set) var queued: String?
    public private(set) var sessionID: String?
    public private(set) var totalCost: Double?
    /// The last stored event applied; pass it as `since` to catch up.
    public private(set) var lastSeq = 0

    public init() {}

    public init(events: [WorkspaceEvent]) {
        for event in events { apply(event) }
    }

    public mutating func apply(_ event: WorkspaceEvent) {
        if !event.kind.isLiveOnly { lastSeq = max(lastSeq, event.seq) }

        switch event.kind {
        case .prompt(let text):
            items.append(ChatItem(id: Self.itemID(event.seq), kind: .user, text: text))
            running = true
            turnStarted = event.at
            streaming = ""
            queued = nil

        case .queued(let text):
            queued = text.isEmpty ? nil : text

        case .sessionStarted(let id):
            sessionID = id

        case .textDelta(let text):
            streaming += text

        case .partial(let text):
            streaming = text

        case .text(let text):
            streaming = ""
            items.append(ChatItem(id: Self.itemID(event.seq), kind: .assistant, text: text))

        case .toolUse(let id, let name, let summary):
            streaming = ""
            items.append(ChatItem(id: Self.itemID(event.seq), kind: .tool, text: name, detail: summary, toolID: id))

        case .toolResult(let id, let isError, let output):
            guard let t = items.lastIndex(where: { $0.kind == .tool && $0.toolID == id }) else { break }
            items[t].isError = isError
            // Shell output becomes a terminal block; for other tools only a
            // failure is worth showing.
            if items[t].isShell || isError { items[t].output = output }

        case .turnResult(let isError, let message, let durationMs, let costUSD, let sessionID):
            if let sessionID { self.sessionID = sessionID }
            if isError {
                items.append(ChatItem(id: Self.itemID(event.seq), kind: .error,
                                      text: message ?? "claude reported an error"))
            }
            var parts: [String] = []
            if let durationMs { parts.append(String(format: "%.1fs", Double(durationMs) / 1000)) }
            if let costUSD {
                parts.append(String(format: "$%.3f", costUSD))
                totalCost = (totalCost ?? 0) + costUSD
            }
            if !parts.isEmpty {
                items.append(ChatItem(id: Self.itemID(event.seq, slot: 1), kind: .meta,
                                      text: parts.joined(separator: " · ")))
            }

        case .turnEnded(let cancelled, let partial):
            if cancelled {
                items.append(ChatItem(id: Self.itemID(event.seq), kind: .meta, text: "stopped"))
                // Stopping also drops the queue: the user is taking over.
                queued = nil
            }
            if let partial, !partial.isEmpty {
                items.append(ChatItem(id: Self.itemID(event.seq, slot: 1), kind: .assistant, text: partial))
            }
            streaming = ""
            running = false
            turnStarted = nil

        case .note(let text, let isError):
            items.append(ChatItem(id: Self.itemID(event.seq), kind: isError ? .error : .meta, text: text))

        case .legacy(let item):
            items.append(item)
        }
    }

    /// A row's id, from the event that made it, so every client derives the
    /// same ids. `slot` tells apart two rows from one event.
    static func itemID(_ seq: Int, slot: UInt8 = 0) -> UUID {
        let s = UInt64(seq)
        func byte(_ shift: UInt64) -> UInt8 { UInt8((s >> shift) & 0xFF) }
        return UUID(uuid: (0x70, 0x73, 0x79, 0x64, 0x75, 0x63, 0x6B, slot,
                           byte(56), byte(48), byte(40), byte(32), byte(24), byte(16), byte(8), byte(0)))
    }
}
