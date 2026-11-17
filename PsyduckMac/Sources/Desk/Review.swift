import Combine
import Foundation
import PsyduckCore

struct CodeLine: Codable, Hashable {
    let no: Int
    let mark: String
    let text: String
}

struct ContextSnippet: Codable, Hashable {
    let why: String
    let file: String
    let lines: String
    let tag: String
    let code: [CodeLine]
    let highlight: [Int]
}

struct ReviewComment: Codable, Hashable {
    enum Severity: String, Codable, CaseIterable {
        case blocking
        case shouldFix = "should fix"
        case nit
    }

    let severity: Severity
    let file: String
    let lines: String
    let title: String
    /// The problem.
    let body: String
    /// Ways to fix it. Reviews from before 0.7.1 have none.
    var fixes: [String]? = nil
    let code: [CodeLine]
    let highlight: [Int]
    let context: [ContextSnippet]
    let asks: [String]
    /// The agents that raised it — more than one when checking merged them.
    var foundBy: [String]? = nil
    /// Its checker didn't finish, so it is shown as found.
    var unchecked: Bool? = nil
}

extension ReviewComment {
    var fixList: [String] { fixes ?? [] }

    /// The whole comment in one paragraph, for prompts.
    var plain: String {
        let fix: String
        switch fixList.count {
        case 0: fix = ""
        case 1: fix = " Fix: " + fixList[0]
        default: fix = " Possible fixes: " + fixList.enumerated().map { "(\($0 + 1)) \($1)" }.joined(separator: " ")
        }
        return "\(title). \(body)" + fix
    }
}

/// What claude sends back, plus what desk measured while it worked.
struct Review: Codable, Hashable {
    /// Whether claude would approve the PR as it stands.
    enum Verdict: String, Codable {
        case approve, hold
    }

    let summary: String
    let comments: [ReviewComment]
    var verdict: Verdict?
    var reason = ""
    var filesRead = 0
    var contextFiles = 0
    var seconds = 0
    var headSha = ""
    /// How many claude processes it took, and how many findings they raised
    /// before checking. 0 for reviews from before v0.6, which ran as one.
    var agents = 0
    var raised = 0
    var dropped: [DroppedFinding] = []

    enum CodingKeys: String, CodingKey {
        case summary, comments, verdict, reason, filesRead, contextFiles, seconds, headSha, agents, raised, dropped
    }

    init(summary: String, comments: [ReviewComment], verdict: Verdict? = nil, reason: String = "") {
        self.summary = summary
        self.comments = comments
        self.verdict = verdict
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        comments = try c.decode([ReviewComment].self, forKey: .comments)
        // Reviews from before v0.2 have no verdict.
        verdict = try c.decodeIfPresent(Verdict.self, forKey: .verdict)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        filesRead = try c.decodeIfPresent(Int.self, forKey: .filesRead) ?? 0
        contextFiles = try c.decodeIfPresent(Int.self, forKey: .contextFiles) ?? 0
        seconds = try c.decodeIfPresent(Int.self, forKey: .seconds) ?? 0
        headSha = try c.decodeIfPresent(String.self, forKey: .headSha) ?? ""
        agents = try c.decodeIfPresent(Int.self, forKey: .agents) ?? 0
        raised = try c.decodeIfPresent(Int.self, forKey: .raised) ?? 0
        dropped = try c.decodeIfPresent([DroppedFinding].self, forKey: .dropped) ?? []
    }

    /// "read 4 changed files · 9 agents · kept 3 of 8 findings · pulled
    /// context from 3 more · 41s" — the view
    /// puts the agent's name in front.
    var meta: String {
        var parts = ["read \(filesRead) changed file\(filesRead == 1 ? "" : "s")"]
        if agents > 0 { parts.append("\(agents) agents · kept \(comments.count) of \(raised) finding\(raised == 1 ? "" : "s")") }
        if contextFiles > 0 { parts.append("pulled context from \(contextFiles) more") }
        parts.append("\(seconds)s")
        return parts.joined(separator: " · ")
    }
}

struct ChatMessage: Codable, Hashable {
    enum Role: String, Codable { case user, assistant, error }
    let role: Role
    let text: String
}

/// A finished review and the conversations about its comments. This is what
/// is kept on disk, so reviews survive a relaunch.
struct ReviewRecord: Codable, Hashable {
    var review: Review
    var threads: [String: [ChatMessage]] = [:]

    func thread(_ index: Int) -> [ChatMessage] { threads[String(index)] ?? [] }
}

/// A review in progress, or the last one that didn't finish. A finished
/// review is a `ReviewRecord`, and stays on screen while the next one runs.
enum ReviewRun: Equatable {
    case running(ReviewProgress)
    case failed(String)
}

/// Runs reviews with the claude cli and keeps them. Nothing here ever
/// writes to GitHub — the prompts say so, and only read commands are allowed.
@MainActor
final class ReviewStore: ObservableObject {
    @Published private(set) var records: [DeskPullRequest.ID: ReviewRecord] = [:]
    @Published private(set) var runs: [DeskPullRequest.ID: ReviewRun] = [:]
    @Published private(set) var pendingChats: Set<String> = []
    @Published var drafts: [String: String] = [:]
    @Published var closedContext: Set<String> = []

    private let settings: DeskSettings
    private let file: URL
    private var tasks: [DeskPullRequest.ID: Task<Void, Never>] = [:]

    // Background reviews run one at a time, from this queue.
    private var queue: [DeskPullRequest] = []
    @Published private(set) var backgroundRun: DeskPullRequest.ID?
    /// The commit each PR was last queued at, so a review that fails isn't
    /// retried every sync. New commits, or "run again", try again.
    private var tried: [DeskPullRequest.ID: String] = [:]
    private var following: AnyCancellable?
    private var limiting: AnyCancellable?
    let limiter: AgentLimiter

    init(settings: DeskSettings, file: URL = DeskFolder.directory.appendingPathComponent("reviews.json")) {
        self.settings = settings
        self.file = file
        limiter = AgentLimiter { [weak settings] in settings?.agentLimit }
        load()
        // A higher limit lets waiting agents start now, not when one finishes.
        limiting = settings.$maxAgents.sink { [weak self] _ in
            Task { @MainActor in self?.limiter.pump() }
        }
    }

    func record(_ pr: DeskPullRequest) -> ReviewRecord? { records[pr.id] }
    func run(_ pr: DeskPullRequest) -> ReviewRun? { runs[pr.id] }

    func isRunning(_ pr: DeskPullRequest) -> Bool {
        if case .running = runs[pr.id] { return true }
        return false
    }

    /// The review is of a commit the PR has moved on from.
    func isOutdated(_ pr: DeskPullRequest) -> Bool {
        guard let sha = records[pr.id]?.review.headSha, !sha.isEmpty, !pr.headSha.isEmpty else { return false }
        return sha != pr.headSha
    }

    static func key(_ pr: DeskPullRequest, _ index: Int) -> String { "\(pr.id)/\(index)" }

    // MARK: Review

    func start(_ pr: DeskPullRequest, background: Bool = false) {
        if isRunning(pr) { return }
        runs[pr.id] = .running(ReviewProgress(background: background))
        contextPaths[pr.id] = nil
        tasks[pr.id] = Task {
            await review(pr)
            if background {
                backgroundRun = nil
                next()
            }
        }
    }

    // MARK: Background

    /// Keeps up with the review list: every sync, anything new or with new
    /// commits gets queued.
    func follow(_ prs: PRStore) {
        following = prs.$lists.sink { [weak self] lists in
            Task { @MainActor in self?.catchUp(lists.review) }
        }
    }

    func catchUp(_ candidates: [DeskPullRequest]) {
        queue = settings.autoReview ? candidates.filter(needsBackgroundReview) : []
        next()
    }

    func needsBackgroundReview(_ pr: DeskPullRequest) -> Bool {
        guard pr.status != .draft, !pr.headSha.isEmpty, !isRunning(pr) else { return false }
        if records[pr.id]?.review.headSha == pr.headSha { return false }
        return tried[pr.id] != pr.headSha
    }

    private func next() {
        guard backgroundRun == nil, settings.autoReview else { return }
        while !queue.isEmpty {
            let pr = queue.removeFirst()
            guard needsBackgroundReview(pr) else { continue }
            tried[pr.id] = pr.headSha
            backgroundRun = pr.id
            start(pr, background: true)
            return
        }
    }

    private func review(_ pr: DeskPullRequest) async {
        let began = Date()
        let specialists = settings.specialists
        do {
            let claude = try settings.claude()

            // 1 and 2 run side by side; the first pass decides 3.
            let jobs = specialists.map { (id: $0.id, name: $0.name, prompt: Self.specialistPrompt(pr, $0)) }
            async let specialistFindings = findings(pr, claude, stage: .specialists, jobs: jobs)
            register(pr, AgentRun(id: "first", stage: .firstPass, name: "first pass"))
            let first = try JSONDecoder().decode(FirstPass.self, from: try await agent(pr, claude, id: "first", stage: .firstPass,
                prompt: Self.firstPassPrompt(pr, template: settings.reviewTemplate, specialists: specialists),
                schema: Self.firstPassSchema, found: { try JSONDecoder().decode(FirstPass.self, from: $0).comments.count }))

            let focusFindings = await findings(pr, claude, stage: .focus,
                jobs: first.focus.enumerated().map { ("focus\($0)", $1.title, Self.focusPrompt(pr, $1, summary: first.summary)) })
            let raised = first.comments.map { Finding(comment: $0, by: "first pass") } + (await specialistFindings) + focusFindings

            // 4: every finding is checked by an agent that re-reads its file.
            let groups = Finding.byFile(raised)
            for (i, group) in groups.enumerated() {
                register(pr, AgentRun(id: "verify\(i)", stage: .verify, name: group[0].comment.file.isEmpty ? "general" : group[0].comment.file))
            }
            let results = await withTaskGroup(of: (Int, [ReviewComment], [DroppedFinding]).self) { tasks in
                for (i, group) in groups.enumerated() {
                    tasks.addTask { @MainActor in
                        do {
                            let output = try await self.agent(pr, claude, id: "verify\(i)", stage: .verify,
                                prompt: Self.verifyPrompt(pr, group), schema: Self.verifySchema,
                                found: { try Self.checked(group, output: $0).kept.count })
                            let result = try Self.checked(group, output: output)
                            return (i, result.kept, result.dropped)
                        } catch {
                            // Unchecked beats lost: show what was found, and say so.
                            return (i, group.map { var c = $0.comment; c.foundBy = [$0.by]; c.unchecked = true; return c }, [])
                        }
                    }
                }
                return await tasks.reduce(into: []) { $0.append($1) }.sorted { $0.0 < $1.0 }
            }
            try Task.checkCancellation()

            let comments = Self.ordered(results.flatMap(\.1))
            let (verdict, reason) = Self.verdict(comments, first: first)
            var review = Review(summary: first.summary, comments: comments, verdict: verdict, reason: reason)
            review.filesRead = pr.changedFiles
            review.contextFiles = progress(pr)?.contextFiles ?? 0
            review.seconds = Int(Date().timeIntervalSince(began).rounded())
            review.headSha = pr.headSha
            review.agents = progress(pr)?.agents.count ?? 0
            review.raised = raised.count
            review.dropped = results.flatMap(\.2)
            records[pr.id] = ReviewRecord(review: review)
            runs[pr.id] = nil
            closedContext = closedContext.filter { !$0.hasPrefix(pr.id + "/") }
            save()
        } catch is CancellationError {
            runs[pr.id] = nil
        } catch {
            runs[pr.id] = .failed(error.localizedDescription)
        }
    }

    /// Runs a stage's agents side by side. One that fails is marked and
    /// skipped — the rest of the review still counts.
    private func findings(_ pr: DeskPullRequest, _ claude: String, stage: ReviewStage,
                          jobs: [(id: String, name: String, prompt: String)]) async -> [Finding] {
        struct Answer: Decodable { let comments: [ReviewComment] }
        for job in jobs { register(pr, AgentRun(id: job.id, stage: stage, name: job.name)) }
        return await withTaskGroup(of: (Int, [Finding]).self) { tasks in
            for (i, job) in jobs.enumerated() {
                tasks.addTask { @MainActor in
                    guard let output = try? await self.agent(pr, claude, id: job.id, stage: stage, prompt: job.prompt,
                                                             schema: Self.findingsSchema,
                                                             found: { try JSONDecoder().decode(Answer.self, from: $0).comments.count }),
                          let answer = try? JSONDecoder().decode(Answer.self, from: output) else { return (i, []) }
                    return (i, answer.comments.map { Finding(comment: $0, by: job.name) })
                }
            }
            return await tasks.reduce(into: []) { $0.append($1) }.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    /// One `claude -p`, read-only, waiting its turn under the agent limit.
    /// Returns the structured output; `found` counts it for the UI.
    private func agent(_ pr: DeskPullRequest, _ claude: String, id: String, stage: ReviewStage,
                       prompt: String, schema: String, found: (Data) throws -> Int) async throws -> Data {
        try await limiter.acquire()
        defer { limiter.release() }
        update(pr, id) { $0.state = .running }
        let stream = AgentStream()
        let model = settings.model(stage)
        do {
            let result = try await Shell.stream(claude, [
                "-p", prompt,
                "--append-system-prompt", Self.readOnly,
                "--output-format", "stream-json", "--verbose",
                "--json-schema", schema]
                + (model.isEmpty ? [] : ["--model", model])
                + ["--allowedTools"] + Self.readTools + ["--no-session-persistence"],
                directory: ClaudeWorkspace.directory
            ) { line in
                if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { stream.consume(event) }
            }
            try Task.checkCancellation()
            guard let output = stream.output else {
                throw PRError.tool("claude", stream.error ?? result.stderr.split(separator: "\n").first.map(String.init) ?? "no answer came back")
            }
            let count = (try? found(output)) ?? 0
            update(pr, id) { $0.state = .done(found: count) }
            addContext(pr, stream.contextPaths)
            return output
        } catch {
            update(pr, id) { $0.state = .failed }
            throw error
        }
    }

    // MARK: Progress

    /// Puts a review in a given state without running anything — for
    /// rendering screens.
    func show(_ pr: DeskPullRequest, _ run: ReviewRun) { runs[pr.id] = run }

    func progress(_ pr: DeskPullRequest) -> ReviewProgress? {
        if case .running(let progress) = runs[pr.id] { return progress }
        return nil
    }

    private func register(_ pr: DeskPullRequest, _ agent: AgentRun) {
        guard var progress = progress(pr) else { return }
        progress.agents.append(agent)
        runs[pr.id] = .running(progress)
    }

    private func update(_ pr: DeskPullRequest, _ id: String, _ change: (inout AgentRun) -> Void) {
        guard var progress = progress(pr), let i = progress.agents.firstIndex(where: { $0.id == id }) else { return }
        change(&progress.agents[i])
        runs[pr.id] = .running(progress)
    }

    private var contextPaths: [DeskPullRequest.ID: Set<String>] = [:]

    private func addContext(_ pr: DeskPullRequest, _ paths: Set<String>) {
        guard var progress = progress(pr) else { return }
        contextPaths[pr.id, default: []].formUnion(paths)
        progress.contextFiles = contextPaths[pr.id]!.count
        runs[pr.id] = .running(progress)
    }

    /// Reads one agent's event stream for its answer, and for the files it
    /// pulled in from outside the diff.
    final class AgentStream: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        private var answer: Data?
        private var failure: String?

        var contextPaths: Set<String> { lock.withLock { paths } }
        var output: Data? { lock.withLock { answer } }
        var error: String? { lock.withLock { failure } }

        func consume(_ event: [String: Any]) {
            lock.withLock {
                switch event["type"] as? String {
                case "assistant":
                    let message = event["message"] as? [String: Any]
                    for item in message?["content"] as? [[String: Any]] ?? [] where item["type"] as? String == "tool_use" {
                        let command = (item["input"] as? [String: Any])?["command"] as? String ?? ""
                        if let path = Self.contentsPath(command) { paths.insert(path) }
                    }
                case "result":
                    if let output = event["structured_output"] {
                        answer = try? JSONSerialization.data(withJSONObject: output)
                    }
                    if event["is_error"] as? Bool == true { failure = event["result"] as? String }
                default:
                    break
                }
            }
        }

        /// `repos/o/r/contents/lib/session.ts?ref=…` → `lib/session.ts`
        static func contentsPath(_ command: String) -> String? {
            guard let range = command.range(of: "/contents/") else { return nil }
            let rest = command[range.upperBound...]
            let end = rest.firstIndex(where: { "?' \"".contains($0) }) ?? rest.endIndex
            return String(rest[..<end])
        }
    }

    // MARK: Chat

    func ask(_ pr: DeskPullRequest, comment index: Int, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.key(pr, index)
        guard !text.isEmpty, !pendingChats.contains(key), var record = records[pr.id] else { return }

        var thread = record.thread(index)
        // A failed attempt and the question that caused it are not worth
        // sending again as history.
        if thread.last?.role == .error {
            thread.removeLast()
            if thread.last?.role == .user { thread.removeLast() }
        }
        thread.append(ChatMessage(role: .user, text: text))
        record.threads[String(index)] = thread
        records[pr.id] = record
        drafts[key] = ""
        pendingChats.insert(key)

        let comment = record.review.comments[index]
        Task {
            var reply: ChatMessage
            do {
                let claude = try settings.claude()
                let result = try await Shell.run(claude, [
                    "-p", Self.chatPrompt(thread),
                    "--append-system-prompt", Self.chatContext(pr, comment),
                    "--output-format", "json",
                    "--allowedTools"] + Self.readTools + ["--no-session-persistence"],
                    directory: ClaudeWorkspace.directory)
                let envelope = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
                if result.ok, envelope?["is_error"] as? Bool != true, let answer = envelope?["result"] as? String, !answer.isEmpty {
                    reply = ChatMessage(role: .assistant, text: Self.plain(answer))
                } else {
                    reply = ChatMessage(role: .error, text: "couldn't reach \(settings.agent). try again?")
                }
            } catch {
                reply = ChatMessage(role: .error, text: "couldn't reach \(settings.agent). try again?")
            }
            pendingChats.remove(key)
            // A new review replaces the comments; this reply was about an old one.
            guard var latest = self.records[pr.id], latest.review == record.review else { return }
            latest.threads[String(index), default: []].append(reply)
            records[pr.id] = latest
            save()
        }
    }

    /// Markdown claude slips in anyway, flattened to what the UI renders.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"```\w*\n?"#, with: "`", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let records = try? JSONDecoder().decode([String: ReviewRecord].self, from: data) else { return }
        self.records = records
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: Prompts

    static let readTools = [
        "Bash(gh pr diff:*)", "Bash(gh pr view:*)", "Bash(gh api:*)",
        "Bash(base64:*)", "Bash(cat:*)", "Bash(nl:*)", "Bash(sed:*)", "Bash(head:*)", "Bash(grep:*)"
    ]

    static let readOnly = """
    You are reviewing a GitHub pull request for a developer inside psyduck, a desktop app. \
    Your review stays in psyduck. Only ever read from GitHub: never comment, review, approve, \
    request changes, merge, push, or send anything that isn't a GET request.
    """

    /// What a review prompt can refer to, and what each stands for.
    static let placeholders: [(String, String)] = [
        ("{url}", "the pull request's url"), ("{ref}", "owner/repo#number"), ("{title}", "its title"),
        ("{author}", "who opened it"), ("{repo}", "owner/repo"), ("{number}", "its number"),
        ("{head}", "the branch being merged"), ("{base}", "the branch it merges into"),
        ("{sha}", "the commit being reviewed")
    ]

    /// The prompt desk ships with. Settings can replace it; the read-only
    /// rules (`readOnly`) and the answer's shape (`firstPassSchema`) stay fixed.
    nonisolated static let defaultReviewPrompt = """
    Review {url} ({ref}, "{title}") by {author}, merging {head} into {base} at commit {sha}.

    1. Read the diff: gh pr diff {number} --repo {repo}
    2. Pull in whatever code outside the diff you need to understand the change, for example
       gh api 'repos/{repo}/contents/PATH?ref={sha}' --jq .content | base64 -d | cat -n
       (ref={base} shows how it looks before this change).
    3. Report only what is worth a reviewer's time, most important first: "blocking" for bugs, \
    security holes or data loss; "should fix" for real problems that aren't emergencies; "nit" \
    for small things. No comments at all is a fine answer for a sound change.

    For each comment:
    - code: the lines it is about, copied exactly, with real line numbers — new-file numbers for \
    added ("+") and unchanged (" ") lines, old-file numbers for removed ("-") lines. At most 12 lines. \
    highlight: the line numbers that matter most.
    - context: snippets from outside the diff that explain the comment, each with why it matters \
    and a tag such as "unchanged in this PR", "outside this PR" or "{base} · removed in this PR". May be empty.
    - asks: two short follow-up questions the developer might want to ask about it.

    Finally, say whether you would approve this pull request as it stands. verdict: "approve" \
    if it is sound and ready to merge — nits alone don't hold an approval back; "hold" if \
    anything blocking or should-fix needs to change first, or you can't tell that it's safe. \
    reason: one sentence saying why, for the developer deciding whether to approve.

    Write plainly: no markdown headings, bold or bullet lists. Wrap code identifiers in single \
    backticks. The summary is two or three sentences.
    """

    static func reviewPrompt(_ pr: DeskPullRequest, template: String = defaultReviewPrompt) -> String {
        let values: [String: String] = [
            "{url}": pr.url, "{ref}": pr.ref, "{title}": pr.title, "{author}": pr.author,
            "{repo}": pr.repo, "{number}": String(pr.number), "{head}": pr.headRef, "{base}": pr.baseRef,
            "{sha}": pr.headSha.isEmpty ? pr.headRef : pr.headSha
        ]
        return values.reduce(template) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    static func chatContext(_ pr: DeskPullRequest, _ c: ReviewComment) -> String {
        func code(_ lines: [CodeLine]) -> String { lines.map { "\($0.no) \($0.mark) \($0.text)" }.joined(separator: "\n") }
        var parts = [
            readOnly,
            "The developer is asking follow-up questions about one of your review comments.",
            "Answer in plain text, under 120 words. No markdown headings, bold or bullet lists. Wrap code identifiers in single backticks. Short code snippets are fine on their own lines. Be direct and concrete. You may read more code with gh if you need to.",
            "PR: \(pr.ref) \"\(pr.title)\" — \(pr.url)",
            "Description:\n\(pr.body)",
            "Your comment (\(c.severity.rawValue)) on \(c.file) \(c.lines): \(c.plain)",
            "Reviewed code:\n\(code(c.code))"
        ]
        parts += c.context.map { "Context from \($0.file) \($0.lines) (\($0.tag)): \($0.why)\n\(code($0.code))" }
        return parts.joined(separator: "\n\n")
    }

    static func chatPrompt(_ thread: [ChatMessage]) -> String {
        guard thread.count > 1 else { return thread.last?.text ?? "" }
        let history = thread.dropLast().map { ($0.role == .user ? "Developer: " : "You: ") + $0.text }
        return "The conversation so far:\n\n" + history.joined(separator: "\n\n")
            + "\n\nThe developer now asks: " + (thread.last?.text ?? "")
    }
}

/// A review comment written up for another claude to fix: where, what's
/// wrong, the code, the context, and anything the developer worked out in
/// the comment's thread.
enum FixPrompt {
    static func comment(_ c: ReviewComment, thread: [ChatMessage], pr: DeskPullRequest) -> String {
        header(pr) + "\n\n" + section(c, thread: thread)
    }

    static func review(_ record: ReviewRecord, pr: DeskPullRequest) -> String {
        let comments = record.review.comments.enumerated().map { index, c in
            "## \(index + 1). " + section(c, thread: record.thread(index), heading: false)
        }
        return ([header(pr), "Review summary: \(record.review.summary)"] + comments).joined(separator: "\n\n")
    }

    private static func header(_ pr: DeskPullRequest) -> String {
        "Fix this review feedback on \(pr.url) (\(pr.ref), \"\(pr.title)\"), branch `\(pr.headRef)` into `\(pr.baseRef)`."
    }

    private static func section(_ c: ReviewComment, thread: [ChatMessage], heading: Bool = true) -> String {
        var parts = ["\(heading ? "## " : "")[\(c.severity.rawValue)] \(c.title) — \(c.file) \(c.lines)", c.body]
        if !c.fixList.isEmpty { parts.append("Possible fixes:\n" + c.fixList.map { "- " + $0 }.joined(separator: "\n")) }
        if !c.code.isEmpty { parts.append(code(c.file, c.code)) }
        for snippet in c.context {
            parts.append("Context, \(snippet.file) \(snippet.lines) (\(snippet.tag)): \(snippet.why)\n" + code(snippet.file, snippet.code))
        }
        let talk = thread.filter { $0.role != .error }
        if !talk.isEmpty {
            parts.append("Discussion about this comment:\n" + talk.map { ($0.role == .user ? "Developer: " : "Reviewer: ") + $0.text }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func code(_ file: String, _ lines: [CodeLine]) -> String {
        "```\n" + lines.map { "\($0.no) \($0.mark) \($0.text)" }.joined(separator: "\n") + "\n```"
    }
}
