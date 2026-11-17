import Foundation

/// A review runs in four stages, each one or more `claude -p` processes:
///
/// 1. first pass — a quick read of the whole change (the prompt from settings)
/// 2. specialists — one per predefined lens, alongside the first pass
/// 3. digging deeper — one per thing the first pass wanted a closer look at
/// 4. checking — one per file with findings, keeping only what holds up
enum ReviewStage: String, CaseIterable, Codable {
    case firstPass, specialists, focus, verify

    var label: String {
        switch self {
        case .firstPass: return "first pass"
        case .specialists: return "specialists"
        case .focus: return "digging deeper"
        case .verify: return "checking findings"
        }
    }

    var detail: String {
        switch self {
        case .firstPass: return "reads the whole change quickly and picks what deserves a closer look."
        case .specialists: return "one agent per lens below, running alongside the first pass."
        case .focus: return "one agent per thing the first pass flagged."
        case .verify: return "re-reads the code behind every finding and drops what doesn't hold up."
        }
    }

    var defaultModel: String {
        switch self {
        case .firstPass, .specialists: return "sonnet"
        case .focus, .verify: return ""
        }
    }

    /// What settings offers; "" is whatever claude is set up to use.
    static let models = ["", "opus", "sonnet", "haiku"]
}

/// A predefined lens a review always looks through, unless switched off.
struct Specialist: Identifiable, Hashable {
    let id: String
    let name: String
    let brief: String

    static let all: [Specialist] = [
        Specialist(id: "correctness", name: "correctness",
                   brief: "bugs: logic errors, edge cases, off-by-one, empty and nil handling, error paths, races and ordering"),
        Specialist(id: "security", name: "security",
                   brief: "security: injection, auth and permission checks, secrets, unsafe input handling, data exposure"),
        Specialist(id: "style", name: "code style",
                   brief: "code style: whether the change reads like the code around it — naming, idiom, structure, comment density, dead code, and helpers that already exist being rewritten"),
        Specialist(id: "tests", name: "tests",
                   brief: "tests: changed behaviour without tests, missing cases, and tests that don't check what they claim to"),
        Specialist(id: "performance", name: "performance",
                   brief: "performance: needless work in hot paths, N+1 queries, unbounded growth, blocking calls where they hurt"),
        Specialist(id: "compat", name: "compatibility",
                   brief: "compatibility: breaking changes to public interfaces, data formats, migrations and config that existing users or callers depend on")
    ]
}

/// One claude process in a running review, as the UI shows it.
struct AgentRun: Identifiable, Equatable {
    enum State: Equatable { case waiting, running, done(found: Int), failed }

    let id: String
    let stage: ReviewStage
    let name: String
    var state: State = .waiting
}

struct ReviewProgress: Equatable {
    var agents: [AgentRun] = []
    var background: Bool
    var contextFiles = 0

    func agents(_ stage: ReviewStage) -> [AgentRun] { agents.filter { $0.stage == stage } }
}

/// How many claude processes reviews run at once, across every review. A
/// limit changed in settings applies to the next agent that starts.
@MainActor
final class AgentLimiter {
    private let limit: () -> Int?
    private(set) var running = 0
    private var waiting: [(id: UUID, go: CheckedContinuation<Void, Never>)] = []

    init(limit: @escaping () -> Int?) { self.limit = limit }

    private var fits: Bool { limit().map { running < $0 } ?? true }

    func acquire() async throws {
        if waiting.isEmpty && fits {
            running += 1
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting.append((id, $0)) }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        running -= 1
        pump()
    }

    /// Lets waiting agents go while there's room — also after the limit rises.
    func pump() {
        while !waiting.isEmpty && fits {
            running += 1
            waiting.removeFirst().go.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        running += 1
        waiting.remove(at: index).go.resume()
    }
}

/// A comment one agent raised, before it has been checked.
struct Finding: Hashable {
    let comment: ReviewComment
    let by: String

    /// One checker per file, so findings about the same code are weighed —
    /// and merged — together.
    static func byFile(_ findings: [Finding]) -> [[Finding]] {
        var order: [String] = []
        var groups: [String: [Finding]] = [:]
        for finding in findings {
            let file = finding.comment.file
            if groups[file] == nil { order.append(file) }
            groups[file, default: []].append(finding)
        }
        return order.map { groups[$0]! }
    }
}

/// A finding the checkers threw out, and why — kept so the review can say.
struct DroppedFinding: Codable, Hashable {
    let title: String
    let file: String
    let by: String
    let why: String
}

/// What the first pass sends back on top of a review.
struct FirstPass: Decodable {
    struct Focus: Decodable { let title: String; let question: String }

    let summary: String
    let comments: [ReviewComment]
    let verdict: Review.Verdict
    let reason: String
    let focus: [Focus]
}

extension ReviewStore {
    // MARK: Prompts

    /// How every agent writes a comment, so they can be merged and shown alike.
    static let commentFormat = """
    For each comment:
    - severity: "blocking" for bugs, security holes or data loss; "should fix" for real problems \
    that aren't emergencies; "nit" for small things.
    - code: the lines it is about, copied exactly, with real line numbers — new-file numbers for \
    added ("+") and unchanged (" ") lines, old-file numbers for removed ("-") lines. At most 12 lines. \
    highlight: the line numbers that matter most.
    - context: snippets from outside the diff that explain the comment, each with why it matters \
    and a tag such as "unchanged in this PR" or "outside this PR". May be empty.
    - asks: two short follow-up questions the developer might want to ask about it.

    \(commentStyle)
    """

    /// How a comment reads: short, one problem, and what to do about it — a
    /// reviewer should get it at a glance.
    static let commentStyle = """
    Keep every comment short enough to take in at a glance:
    - title: the problem in under ten words.
    - body: the problem only — what goes wrong, and when. One or two short sentences, at most 40 \
    words. No backstory and no fix here.
    - fixes: one to three ways to fix it, each one short sentence starting with a verb. Where there \
    is a real choice (fix it, or confirm it can't happen), make each option its own fix.
    - One problem per comment, on the lines where it happens. When a change causes several problems, \
    or one problem shows up in several places, write one comment for each, each on its own lines, \
    rather than one long comment that covers them all. Detail that explains a comment goes in context.

    Write plainly: no markdown headings, bold or bullet lists. Wrap code identifiers in single backticks.
    """

    static func howToRead(_ pr: DeskPullRequest) -> String {
        let sha = pr.headSha.isEmpty ? pr.headRef : pr.headSha
        return """
        Read the diff: gh pr diff \(pr.number) --repo \(pr.repo)
        Read code outside the diff when you need it: \
        gh api 'repos/\(pr.repo)/contents/PATH?ref=\(sha)' --jq .content | base64 -d | cat -n
        """
    }

    private static func header(_ pr: DeskPullRequest) -> String {
        "Pull request: \(pr.url) (\(pr.ref), \"\(pr.title)\") by \(pr.author), merging \(pr.headRef) into \(pr.baseRef) at commit \(pr.headSha.isEmpty ? pr.headRef : pr.headSha)."
    }

    /// The user's prompt, plus what the first pass owes the stages after it.
    static func firstPassPrompt(_ pr: DeskPullRequest, template: String, specialists: [Specialist]) -> String {
        let covered = specialists.isEmpty ? "" :
            " Specialists are already looking at \(specialists.map(\.name).joined(separator: ", ")) in general, so pick specific questions, not those whole areas."
        return reviewPrompt(pr, template: template) + """


        This is the first pass of a review that other agents continue, so be quick: report what you \
        see, and don't chase every lead yourself. In focus, list up to 4 specific things that deserve \
        a closer look you didn't give them — each a question one agent can investigate on its own, such \
        as "does every caller of `parseToken` handle the new nil return?".\(covered) Leave focus empty \
        if the change is simple enough not to need it.

        \(commentStyle)
        """
    }

    static func specialistPrompt(_ pr: DeskPullRequest, _ specialist: Specialist) -> String {
        """
        \(header(pr))

        You are one of several reviewers, and you look only at \(specialist.brief). Others cover \
        everything else, so stay in your lane.

        \(howToRead(pr))

        Report only real problems in your area that are worth a reviewer's time, most important \
        first. No comments at all is a fine answer.

        \(commentFormat)
        """
    }

    static func focusPrompt(_ pr: DeskPullRequest, _ focus: FirstPass.Focus, summary: String) -> String {
        """
        \(header(pr))

        A first pass over this change summed it up as: \(summary)

        It flagged this for a closer look: \(focus.title). \(focus.question)

        Investigate that properly — read the changed code, its callers, and its tests. \
        \(howToRead(pr))

        Report a comment only for a real problem you found. If it turns out fine, return no comments.

        \(commentFormat)
        """
    }

    static func verifyPrompt(_ pr: DeskPullRequest, _ findings: [Finding]) -> String {
        let listed = findings.enumerated().map { index, finding in
            let c = finding.comment
            let code = c.code.map { "\($0.no) \($0.mark) \($0.text)" }.joined(separator: "\n")
            return "Finding \(index) [\(c.severity.rawValue)] \(c.file) \(c.lines): \(c.plain)\n\(code)"
        }
        return """
        \(header(pr))

        Other reviewers raised these findings about \(findings[0].comment.file). Check each one \
        against the actual code before it reaches the developer.

        \(howToRead(pr))

        Keep a finding only when it is real: the code does what the finding says, it matters, and \
        nothing elsewhere already handles it. Drop anything mistaken, speculative, already handled, \
        or taste dressed up as a bug. Where several describe the same problem, merge them into one \
        comment — but never fold different problems together. If a finding covers several problems, \
        split it: one comment per problem, each on its own lines and each listing that finding in \
        merged. Correct the severity where it's wrong, and rewrite any comment longer than the rules \
        below allow.

        In comments, each kept comment in full, with merged: the numbers of the findings it covers. \
        In dropped, each finding you threw out, with one sentence on why.

        \(commentFormat)

        \(listed.joined(separator: "\n\n"))
        """
    }

    private static let commentProperties = """
    "severity":{"enum":["blocking","should fix","nit"]},
    "file":{"type":"string"},
    "lines":{"type":"string","description":"like L20–29"},
    "title":{"type":"string","description":"the problem, under ten words"},
    "body":{"type":"string","description":"the problem only, one or two short sentences"},
    "fixes":{"type":"array","minItems":1,"maxItems":3,"items":{"type":"string"},"description":"ways to fix it, one short sentence each"},
    "code":{"type":"array","items":{"$ref":"#/$defs/line"}},
    "highlight":{"type":"array","items":{"type":"integer"}},
    "context":{"type":"array","items":{"type":"object",
      "required":["why","file","lines","tag","code","highlight"],
      "properties":{"why":{"type":"string"},"file":{"type":"string"},"lines":{"type":"string"},"tag":{"type":"string"},
        "code":{"type":"array","items":{"$ref":"#/$defs/line"}},
        "highlight":{"type":"array","items":{"type":"integer"}}}}},
    "asks":{"type":"array","items":{"type":"string"},"maxItems":2}
    """

    private static let commentRequired = #""severity","file","lines","title","body","fixes","code","highlight","context","asks""#

    private static let lineDef = """
    "$defs":{"line":{"type":"object","required":["no","mark","text"],
      "properties":{"no":{"type":"integer"},"mark":{"enum":["+","-"," "]},"text":{"type":"string"}}}}
    """

    static let firstPassSchema = """
    {"type":"object","required":["summary","comments","verdict","reason","focus"],"properties":{
      "summary":{"type":"string"},
      "verdict":{"enum":["approve","hold"]},
      "reason":{"type":"string"},
      "focus":{"type":"array","maxItems":4,"items":{"type":"object","required":["title","question"],
        "properties":{"title":{"type":"string","description":"a few words"},"question":{"type":"string"}}}},
      "comments":{"type":"array","items":{"type":"object","required":[\(commentRequired)],"properties":{\(commentProperties)}}}},
     \(lineDef)}
    """

    static let findingsSchema = """
    {"type":"object","required":["comments"],"properties":{
      "comments":{"type":"array","items":{"type":"object","required":[\(commentRequired)],"properties":{\(commentProperties)}}}},
     \(lineDef)}
    """

    static let verifySchema = """
    {"type":"object","required":["comments","dropped"],"properties":{
      "comments":{"type":"array","items":{"type":"object","required":[\(commentRequired),"merged"],"properties":{\(commentProperties),
        "merged":{"type":"array","items":{"type":"integer"}}}}},
      "dropped":{"type":"array","items":{"type":"object","required":["finding","why"],
        "properties":{"finding":{"type":"integer"},"why":{"type":"string"}}}}},
     \(lineDef)}
    """

    // MARK: Putting it together

    /// The call, from what survived checking: anything blocking or should-fix
    /// holds it. The first pass's reason stands when the call agrees with it.
    static func verdict(_ comments: [ReviewComment], first: FirstPass) -> (Review.Verdict, String) {
        let serious = comments.filter { $0.severity != .nit }
        let verdict: Review.Verdict = serious.isEmpty ? .approve : .hold
        if verdict == first.verdict { return (verdict, first.reason) }
        if verdict == .hold {
            return (.hold, "fix first: " + serious.prefix(3).map(\.title).joined(separator: "; ") + ".")
        }
        return (.approve, "the concerns from the first pass didn't hold up when checked, and nothing blocking or should-fix is left.")
    }

    /// Most serious first; ties keep the order they were found in.
    static func ordered(_ comments: [ReviewComment]) -> [ReviewComment] {
        let rank = Dictionary(uniqueKeysWithValues: ReviewComment.Severity.allCases.enumerated().map { ($1, $0) })
        return comments.enumerated()
            .sorted { (rank[$0.element.severity]!, $0.offset) < (rank[$1.element.severity]!, $1.offset) }
            .map(\.element)
    }

    /// A checker's answer, applied to the findings it was given: kept ones
    /// remember who found them, dropped ones say why.
    static func checked(_ findings: [Finding], output: Data) throws -> (kept: [ReviewComment], dropped: [DroppedFinding]) {
        struct Merged: Decodable { let merged: [Int] }
        struct Dropped: Decodable { let finding: Int; let why: String }
        struct Kept: Decodable { let comments: [ReviewComment] }
        struct Raw: Decodable { let comments: [Merged]; let dropped: [Dropped] }

        let comments = try JSONDecoder().decode(Kept.self, from: output).comments
        let raw = try JSONDecoder().decode(Raw.self, from: output)
        let kept = zip(comments, raw.comments).map { comment, merged in
            var comment = comment
            let by = merged.merged.compactMap { findings.indices.contains($0) ? findings[$0].by : nil }
            comment.foundBy = by.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            return comment
        }
        let dropped = raw.dropped.compactMap { d -> DroppedFinding? in
            guard findings.indices.contains(d.finding) else { return nil }
            let f = findings[d.finding]
            return DroppedFinding(title: f.comment.title, file: f.comment.file, by: f.by, why: d.why)
        }
        return (kept, dropped)
    }
}
