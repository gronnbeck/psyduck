import Foundation
import PsyduckCore

/// A line comment in a review you're about to post. It starts as one of
/// claude's comments, pinned to a line GitHub will accept.
struct DraftComment: Codable, Hashable, Identifiable {
    let id: String
    let severity: ReviewComment.Severity
    let title: String
    let path: String
    let lines: String
    let code: [CodeLine]
    let highlight: [Int]
    /// The diff line it posts on. nil when none of its lines are in the
    /// diff — then it goes into the general comment instead.
    let line: Int?
    let startLine: Int?
    let side: String
    var body: String
    var include = true
    /// What claude first wrote, kept beside your edits for the history.
    var drafted: String?

    var onDiff: Bool { line != nil }
}

/// The review you'll post on GitHub: drafted by claude, edited by you.
struct ReviewDraft: Codable, Hashable {
    enum Event: String, Codable, CaseIterable {
        case comment
        case approve
        case requestChanges = "request changes"

        var api: String {
            switch self {
            case .comment: return "COMMENT"
            case .approve: return "APPROVE"
            case .requestChanges: return "REQUEST_CHANGES"
            }
        }
    }

    var body: String
    var event: Event
    var comments: [DraftComment]
    /// The commit claude reviewed. Line numbers are from this commit, so the
    /// review is posted against it.
    let sha: String
    var chat: [ChatMessage] = []
    /// The general comment as claude first wrote it.
    var draftedBody: String?
    var postedAt: Date?
    var postedURL: String?

    var included: [DraftComment] { comments.filter(\.include) }

    /// GitHub wants a general comment for anything but an approval.
    var missingBody: Bool {
        event != .approve && fullBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The general comment, plus any included comment that couldn't be
    /// pinned to a line.
    var fullBody: String {
        let loose = included.filter { !$0.onDiff }.map { "**`\($0.path)` \($0.lines)**\n\n\($0.body)" }
        return ([body.trimmingCharacters(in: .whitespacesAndNewlines)] + loose)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
    }

    struct Payload: Encodable, Equatable {
        struct Comment: Encodable, Equatable {
            let path: String
            let body: String
            let line: Int
            let side: String
            let start_line: Int?
            let start_side: String?
        }
        let commit_id: String
        let body: String
        let event: String
        let comments: [Comment]
    }

    /// What `POST /repos/{repo}/pulls/{n}/reviews` gets.
    var payload: Payload {
        Payload(commit_id: sha, body: fullBody, event: event.api, comments: included.compactMap { c in
            guard let line = c.line else { return nil }
            return .init(path: c.path, body: c.body, line: line, side: c.side,
                         start_line: c.startLine, start_side: c.startLine == nil ? nil : c.side)
        })
    }
}

/// The lines of a unified diff that GitHub lets you comment on, per file and
/// side: added and unchanged lines on the right, removed and unchanged ones
/// on the left.
struct DraftDiffLines {
    private var valid: Set<String> = []

    func contains(_ path: String, _ side: String, _ line: Int) -> Bool {
        valid.contains("\(path)|\(side)|\(line)")
    }

    /// `@@ -20,4 +20,6 @@`: where each side of a hunk starts.
    private static let hunk = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)"#)

    static func parse(_ diff: String) -> DraftDiffLines {
        var result = DraftDiffLines()
        var oldPath: String?
        var path: String?
        var header = false
        var old = 0
        var new = 0
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                header = true
                oldPath = nil
                path = nil
            } else if header, line.hasPrefix("--- ") {
                oldPath = line.hasPrefix("--- a/") ? String(line.dropFirst(6)) : nil
            } else if header, line.hasPrefix("+++ ") {
                path = line.hasPrefix("+++ b/") ? String(line.dropFirst(6)) : oldPath
            } else if line.hasPrefix("@@"), let match = Self.hunk.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let from = Range(match.range(at: 1), in: line), let to = Range(match.range(at: 2), in: line) {
                header = false
                old = Int(line[from]) ?? 0
                new = Int(line[to]) ?? 0
            } else if !header, let file = path {
                switch line.first {
                case " ":
                    result.valid.insert("\(file)|LEFT|\(old)")
                    result.valid.insert("\(file)|RIGHT|\(new)")
                    old += 1
                    new += 1
                case "+":
                    result.valid.insert("\(file)|RIGHT|\(new)")
                    new += 1
                case "-":
                    result.valid.insert("\(file)|LEFT|\(old)")
                    old += 1
                default:
                    break
                }
            }
        }
        return result
    }

    /// Where on the diff a review comment goes: its highlighted lines if
    /// GitHub has them, otherwise any of its lines that it does.
    func anchor(_ c: ReviewComment) -> (line: Int, start: Int?, side: String)? {
        func side(_ no: Int) -> String {
            // Removed lines carry old-file numbers; prefer a new-file match.
            let marks = c.code.filter { $0.no == no }.map(\.mark)
            return marks.contains(where: { $0 != "-" }) || marks.isEmpty ? "RIGHT" : "LEFT"
        }
        let targets = c.highlight.isEmpty ? c.code.map(\.no) : c.highlight
        var found = targets.map { ($0, side($0)) }.filter { contains(c.file, $0.1, $0.0) }
        if found.isEmpty {
            found = c.code.map { ($0.no, $0.mark == "-" ? "LEFT" : "RIGHT") }.filter { contains(c.file, $0.1, $0.0) }
        }
        guard let last = found.max(by: { $0.0 < $1.0 }) else { return nil }
        let end = last.0
        let first = found.filter { $0.1 == last.1 }.map(\.0).min() ?? end
        // A range has to sit inside one hunk: every line between on the diff.
        let start = first < end && (first...end).allSatisfy({ contains(c.file, last.1, $0) }) ? first : nil
        return (end, start, last.1)
    }
}

/// Drafts, edits and posts reviews. Drafting and editing go through claude
/// with no tools at all; posting is desk's own `gh api` call, only when
/// you press post review.
@MainActor
final class DraftStore: ObservableObject {
    @Published private(set) var drafts: [DeskPullRequest.ID: ReviewDraft] = [:]
    /// What's happening to a draft right now: drafting, editing, posting.
    @Published private(set) var busy: [DeskPullRequest.ID: String] = [:]
    @Published private(set) var errors: [DeskPullRequest.ID: String] = [:]
    @Published var input: [DeskPullRequest.ID: String] = [:]

    private let settings: DeskSettings
    private let file: URL
    private let history: URL

    init(settings: DeskSettings, file: URL = DeskFolder.directory.appendingPathComponent("drafts.json"),
         history: URL = DeskFolder.directory.appendingPathComponent("review-history.jsonl")) {
        self.settings = settings
        self.file = file
        self.history = history
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: ReviewDraft].self, from: data) {
            drafts = saved
        }
    }

    func draft(_ pr: DeskPullRequest) -> ReviewDraft? { drafts[pr.id] }

    /// Direct edits from the UI.
    func update(_ pr: DeskPullRequest, _ change: (inout ReviewDraft) -> Void) {
        guard var draft = drafts[pr.id], draft.postedAt == nil else { return }
        change(&draft)
        drafts[pr.id] = draft
        save()
    }

    func discard(_ pr: DeskPullRequest) {
        drafts[pr.id] = nil
        errors[pr.id] = nil
        save()
    }

    // MARK: Drafting

    /// Pins each of claude's comments to the diff, then has claude rewrite
    /// them for the author, taking in what you discussed with it.
    func start(_ pr: DeskPullRequest, from record: ReviewRecord, mine: Bool) {
        guard busy[pr.id] == nil else { return }
        busy[pr.id] = "drafting"
        errors[pr.id] = nil
        Task {
            defer { busy[pr.id] = nil }
            do {
                let gh = try settings.gh()
                let diff = try await Shell.run(gh, ["pr", "diff", String(pr.number), "--repo", pr.repo])
                guard diff.ok else { throw PRError.tool("gh", diff.failureLine) }
                var draft = Self.seed(record, diff: DraftDiffLines.parse(diff.stdout), mine: mine)
                do {
                    let written = try await structured(Self.draftPrompt(pr, record, tone: settings.reviewTone), schema: Self.draftSchema)
                    Self.apply(written, to: &draft, byIndex: true, mine: mine)
                } catch {
                    errors[pr.id] = "\(settings.agent) couldn't draft it, so these are its review comments as they were."
                }
                draft.draftedBody = draft.body
                for i in draft.comments.indices { draft.comments[i].drafted = draft.comments[i].body }
                drafts[pr.id] = draft
                save()
            } catch {
                errors[pr.id] = error.localizedDescription
            }
        }
    }

    /// The draft before claude rewrites it: claude's own words, pinned.
    static func seed(_ record: ReviewRecord, diff: DraftDiffLines, mine: Bool) -> ReviewDraft {
        let review = record.review
        let comments = review.comments.enumerated().map { index, c in
            let anchor = diff.anchor(c)
            return DraftComment(id: String(index), severity: c.severity, title: c.title, path: c.file, lines: c.lines,
                                code: c.code, highlight: c.highlight, line: anchor?.line, startLine: anchor?.start,
                                side: anchor?.side ?? "RIGHT", body: c.plain)
        }
        let event: ReviewDraft.Event
        if mine {
            event = .comment
        } else if review.verdict == .approve {
            event = .approve
        } else if review.comments.contains(where: { $0.severity == .blocking }) {
            event = .requestChanges
        } else {
            event = .comment
        }
        return ReviewDraft(body: review.summary, event: event, comments: comments, sha: review.headSha)
    }

    // MARK: Editing by chat

    func ask(_ pr: DeskPullRequest, _ text: String, mine: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, busy[pr.id] == nil, var draft = drafts[pr.id], draft.postedAt == nil else { return }
        if draft.chat.last?.role == .error { draft.chat.removeLast() }
        draft.chat.append(ChatMessage(role: .user, text: text))
        drafts[pr.id] = draft
        input[pr.id] = ""
        busy[pr.id] = "editing"
        Task {
            defer { busy[pr.id] = nil }
            guard var latest = drafts[pr.id] else { return }
            do {
                let answer = try await structured(Self.editPrompt(pr, latest, tone: settings.reviewTone), schema: Self.editSchema)
                Self.apply(answer, to: &latest, byIndex: false, mine: mine)
                let reply = (answer["reply"] as? String).map(ReviewStore.plain) ?? "done."
                latest.chat.append(ChatMessage(role: .assistant, text: reply.isEmpty ? "done." : reply))
            } catch {
                latest.chat.append(ChatMessage(role: .error, text: "couldn't reach \(settings.agent). try again?"))
            }
            drafts[pr.id] = latest
            save()
        }
    }

    /// Takes claude's rewrite. Only text, inclusion and the event change —
    /// where a comment sits on the diff is never claude's to move.
    static func apply(_ answer: [String: Any], to draft: inout ReviewDraft, byIndex: Bool, mine: Bool) {
        if let body = answer["body"] as? String { draft.body = body }
        if let raw = answer["event"] as? String, let event = ReviewDraft.Event(rawValue: raw), !mine || event == .comment {
            draft.event = event
        }
        for item in answer["comments"] as? [[String: Any]] ?? [] {
            let key = byIndex ? (item["index"] as? Int).map(String.init) : item["id"] as? String
            guard let key, let i = draft.comments.firstIndex(where: { $0.id == key }) else { continue }
            if let body = item["body"] as? String, !body.isEmpty { draft.comments[i].body = body }
            if let include = item["include"] as? Bool { draft.comments[i].include = include }
        }
    }

    // MARK: Posting

    /// The second thing desk writes to GitHub, and only on the button:
    /// one review, as you, through your gh login.
    func post(_ pr: DeskPullRequest) async {
        guard busy[pr.id] == nil, let draft = drafts[pr.id], draft.postedAt == nil, !draft.missingBody else { return }
        busy[pr.id] = "posting"
        errors[pr.id] = nil
        defer { busy[pr.id] = nil }
        do {
            let gh = try settings.gh()
            let input = DeskFolder.directory.appendingPathComponent("post-review.json")
            try JSONEncoder().encode(draft.payload).write(to: input, options: .atomic)
            defer { try? FileManager.default.removeItem(at: input) }
            let result = try await Shell.run(gh, ["api", "-X", "POST", "repos/\(pr.repo)/pulls/\(pr.number)/reviews",
                                                  "--input", input.path, "--jq", ".html_url"])
            guard result.ok else { throw PRError.tool("gh", Self.apiError(result)) }
            var posted = draft
            posted.postedAt = Date()
            posted.postedURL = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            drafts[pr.id] = posted
            save()
            Self.append(PostedReview(pr, posted, tone: settings.reviewTone), to: history)
        } catch {
            errors[pr.id] = error.localizedDescription
        }
    }

    /// gh prints GitHub's JSON error on stdout; the useful part is in there.
    static func apiError(_ result: CommandResult) -> String {
        if let data = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let details = (json["errors"] as? [Any])?.map { "\($0)" }.joined(separator: "; ")
            return [json["message"] as? String, details].compactMap { $0 }.joined(separator: " — ")
        }
        return result.failureLine
    }

    // MARK: History

    /// One line per posted review, kept for good: what was drafted, what you
    /// changed, how you asked, and the tone you'd set. The material for
    /// tuning the tone of voice later.
    static func append(_ entry: PostedReview, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    // MARK: claude

    private func structured(_ prompt: String, schema: String) async throws -> [String: Any] {
        let claude = try settings.claude()
        let result = try await Shell.run(claude, [
            "-p", prompt,
            "--append-system-prompt", Self.system,
            "--output-format", "json",
            "--json-schema", schema,
            "--no-session-persistence"
        ], directory: ClaudeWorkspace.directory)
        let envelope = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        guard result.ok, envelope?["is_error"] as? Bool != true, let output = envelope?["structured_output"] as? [String: Any] else {
            throw PRError.tool("claude", result.failureLine)
        }
        return output
    }

    private func save() {
        if let data = try? JSONEncoder().encode(drafts) {
            try? data.write(to: file, options: .atomic)
        }
    }

    static let system = """
    You are helping a developer write a pull request review inside psyduck, a desktop app. \
    You only write text. Don't run any tools, and never post, comment, approve or change \
    anything on GitHub — the developer posts the review themselves.
    """

    static let baseVoice = """
    Write as the developer, in the first person, to the pull request's author: direct, kind and \
    specific. Say what to change and why, in a few sentences. GitHub markdown is fine; put code \
    in backticks. Don't mention an AI, a reviewer bot or "the review above".
    """

    /// How the comments should sound: desk's default, then the developer's
    /// own guidance from settings, which wins where the two disagree.
    static func voice(_ tone: String) -> String {
        let tone = tone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tone.isEmpty else { return baseVoice }
        return baseVoice + "\n\nThe developer's own guidance on tone of voice — follow it over the above where they differ:\n" + tone
    }

    static func draftPrompt(_ pr: DeskPullRequest, _ record: ReviewRecord, tone: String = "") -> String {
        let review = record.review
        var parts = [
            "Turn this private review of \(pr.ref) \"\(pr.title)\" by \(pr.author) into the review the developer will post on GitHub.",
            voice(tone),
            "Summary: \(review.summary)",
        ]
        if let verdict = review.verdict { parts.append("Verdict: \(verdict.rawValue) — \(review.reason)") }
        for (index, c) in review.comments.enumerated() {
            var text = "Comment \(index) (\(c.severity.rawValue), \(c.file) \(c.lines)): \(c.plain)"
            let talk = record.thread(index).filter { $0.role != .error }
            if !talk.isEmpty {
                text += "\nThe developer discussed it with you:\n" + talk.map { ($0.role == .user ? "Developer: " : "You: ") + $0.text }.joined(separator: "\n")
            }
            parts.append(text)
        }
        parts.append("""
        Return body: the general comment, two or three sentences. And for every comment, by its index: \
        body, the text posted on that line — short: the problem in a sentence or two, then what to do \
        about it, as a short markdown list when there's more than one option, under 60 words in all; include: false only if the developer's discussion concluded it \
        isn't worth raising. Where the discussion changed the conclusion, follow the discussion.
        """)
        return parts.joined(separator: "\n\n")
    }

    static let draftSchema = """
    {"type":"object","required":["body","comments"],"properties":{
      "body":{"type":"string"},
      "comments":{"type":"array","items":{"type":"object","required":["index","body","include"],
        "properties":{"index":{"type":"integer"},"body":{"type":"string"},"include":{"type":"boolean"}}}}}}
    """

    static func editPrompt(_ pr: DeskPullRequest, _ draft: ReviewDraft, tone: String = "") -> String {
        let comments = draft.comments.map { c in
            "[\(c.id)] \(c.include ? "included" : "left out") · \(c.severity.rawValue) · \(c.path) \(c.lines)\n\(c.body)"
        }.joined(separator: "\n\n")
        let history = draft.chat.dropLast().filter { $0.role != .error }
            .map { ($0.role == .user ? "Developer: " : "You: ") + $0.text }.joined(separator: "\n")
        return """
        The developer is editing the review they'll post on \(pr.ref) "\(pr.title)" by \(pr.author). \(voice(tone))

        Submit as: \(draft.event.rawValue)

        General comment:
        \(draft.body)

        Line comments:
        \(comments)
        \(history.isEmpty ? "" : "\nThe conversation so far:\n" + history)

        The developer asks: \(draft.chat.last?.text ?? "")

        Make the change they ask for and nothing else. Return the whole draft: body, event \
        (comment, approve or request changes), and every comment by id with its body and include. \
        reply: one short sentence saying what you changed.
        """
    }

    static let editSchema = """
    {"type":"object","required":["reply","body","event","comments"],"properties":{
      "reply":{"type":"string"},
      "body":{"type":"string"},
      "event":{"enum":["comment","approve","request changes"]},
      "comments":{"type":"array","items":{"type":"object","required":["id","body","include"],
        "properties":{"id":{"type":"string"},"body":{"type":"string"},"include":{"type":"boolean"}}}}}}
    """
}

/// A posted review, as kept in `review-history.jsonl`.
struct PostedReview: Codable, Equatable {
    let pr: String
    let url: String
    let title: String
    let author: String
    let tone: String
    let postedAt: Date
    let postedURL: String
    /// Everything: the posted text, what claude drafted (`draftedBody`,
    /// `comments[].drafted`), what was left out, and the chat.
    let draft: ReviewDraft

    init(_ pr: DeskPullRequest, _ draft: ReviewDraft, tone: String) {
        self.pr = pr.ref
        url = pr.url
        title = pr.title
        author = pr.author
        self.tone = tone
        postedAt = draft.postedAt ?? Date()
        postedURL = draft.postedURL ?? ""
        self.draft = draft
    }
}
