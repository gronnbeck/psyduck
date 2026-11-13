import Foundation

/// What psyduck cares about in claude's `--output-format stream-json` output.
enum ClaudeEvent: Equatable {
    case started(sessionID: String)
    /// A token chunk of the reply being written (needs `--include-partial-messages`).
    case textDelta(String)
    /// A finished text block. Supersedes the deltas before it.
    case text(String)
    case toolUse(id: String, name: String, summary: String)
    /// What a tool returned. Shown for shell commands, as a terminal block.
    case toolResult(id: String, isError: Bool, output: String)
    case finished(isError: Bool, message: String?, durationMs: Int?, costUSD: Double?, sessionID: String?)
}

enum ClaudeStream {
    /// Parses one line of stream-json. Lines it doesn't recognise yield nothing.
    static func parse(_ line: Data) -> [ClaudeEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return [] }

        // A subagent's own messages carry the tool call that spawned it. Its
        // work shows up as that one tool row, not interleaved with the reply.
        if object["parent_tool_use_id"] is String { return [] }

        switch type {
        case "system":
            if object["subtype"] as? String == "init", let id = object["session_id"] as? String {
                return [.started(sessionID: id)]
            }
            return []

        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return [] }
            return [.textDelta(text)]

        case "assistant":
            let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return .text(text)
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    return .toolUse(id: block["id"] as? String ?? "", name: name,
                                    summary: summarize(block["input"] as? [String: Any] ?? [:]))
                default:
                    return nil
                }
            }

        case "user":
            let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { block in
                guard block["type"] as? String == "tool_result" else { return nil }
                return .toolResult(id: block["tool_use_id"] as? String ?? "",
                                   isError: block["is_error"] as? Bool == true,
                                   output: resultText(block["content"]))
            }

        case "result":
            let isError = object["is_error"] as? Bool ?? (object["subtype"] as? String != "success")
            return [.finished(
                isError: isError,
                message: isError ? (object["result"] as? String ?? object["subtype"] as? String) : nil,
                durationMs: object["duration_ms"] as? Int,
                costUSD: object["total_cost_usd"] as? Double,
                sessionID: object["session_id"] as? String)]

        default:
            return []
        }
    }

    /// The one argument worth showing for a tool call.
    static func summarize(_ input: [String: Any]) -> String {
        for key in ["command", "file_path", "notebook_path", "pattern", "url", "query", "path", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                let line = value.split(separator: "\n").first.map(String.init) ?? value
                return line.count > 160 ? String(line.prefix(160)) + "…" : line
            }
        }
        return ""
    }

    private static func resultText(_ content: Any?) -> String {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            text = ""
        }
        // Long output is kept to its tail: that's where test summaries and errors are.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.count > 40 ? ["…"] + lines.suffix(40) : lines[...]
        return String(tail.joined(separator: "\n").suffix(6_000))
    }
}
