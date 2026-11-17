import XCTest
@testable import Psyduck

final class GhPullRequestsTests: XCTestCase {
    private let response = """
    {"data":{
      "review":{"nodes":[
        {"number":1482,"title":"Migrate auth middleware to the edge runtime","url":"https://github.com/acme/web-app/pull/1482",
         "body":"Moves it.","isDraft":false,"additions":312,"deletions":88,"changedFiles":4,"updatedAt":"2026-10-28T08:00:00Z",
         "headRefName":"mkato/edge-auth","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED",
         "repository":{"nameWithOwner":"acme/web-app"},"author":{"login":"mkato"},
         "reviewRequests":{"nodes":[{"requestedReviewer":{"login":"you"}}]},
         "commits":{"nodes":[{"commit":{"oid":"abc123","statusCheckRollup":{"state":"SUCCESS"}}}]},
         "viewerLatestReview":{"state":"APPROVED","commit":{"oid":"9a9"}}},
        {}
      ]},
      "mine":{"nodes":[
        {"number":12,"title":"PR list: read gh path from settings","url":"https://github.com/np-lol/desk/pull/12",
         "body":"","isDraft":true,"additions":204,"deletions":31,"changedFiles":3,"updatedAt":"2026-10-28T09:40:00Z",
         "headRefName":"you/settings-paths","baseRefName":"main","reviewDecision":null,
         "repository":{"nameWithOwner":"np-lol/desk"},"author":{"login":"you"},
         "reviewRequests":{"nodes":[]},
         "commits":{"nodes":[{"commit":{"oid":"def456","statusCheckRollup":null}}]}},
        {"number":899,"title":"Cache user settings in redis","url":"https://github.com/acme/api/pull/899",
         "body":"","isDraft":false,"additions":97,"deletions":14,"changedFiles":2,"updatedAt":"2026-10-26T10:00:00Z",
         "headRefName":"you/redis-settings","baseRefName":"main","reviewDecision":"CHANGES_REQUESTED",
         "repository":{"nameWithOwner":"acme/api"},"author":{"login":"you"},
         "reviewRequests":{"nodes":[{"requestedReviewer":{"name":"backend"}}]},
         "commits":{"nodes":[{"commit":{"oid":"0f0","statusCheckRollup":{"state":"FAILURE"}}}]}}
      ]}}}
    """

    func testParsesBothLists() throws {
        let lists = try GhPullRequests.parse(Data(response.utf8))

        XCTAssertEqual(lists.review.map(\.id), ["acme/web-app#1482"])
        XCTAssertEqual(lists.mine.map(\.id), ["np-lol/desk#12", "acme/api#899"])
    }

    func testMapsChecksAndStatus() throws {
        let lists = try GhPullRequests.parse(Data(response.utf8))
        let review = lists.review[0]
        let draft = lists.mine[0]
        let changes = lists.mine[1]

        XCTAssertEqual(review.checks, .passing)
        XCTAssertEqual(review.status, .review)
        XCTAssertEqual(review.headSha, "abc123")
        XCTAssertEqual(review.approvedSha, "9a9")
        XCTAssertNil(draft.approvedSha)
        XCTAssertEqual(draft.checks, .none)
        XCTAssertEqual(draft.status, .draft)
        XCTAssertEqual(draft.reviewersLabel, "no reviewers yet")
        XCTAssertEqual(changes.checks, .failing)
        XCTAssertEqual(changes.status, .changes)
        XCTAssertEqual(changes.reviewersLabel, "backend")
    }

    func testAGraphQLErrorIsReported() {
        let body = #"{"data":null,"errors":[{"message":"Bad credentials"}]}"#

        XCTAssertThrowsError(try GhPullRequests.parse(Data(body.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "gh failed: Bad credentials")
        }
    }
}

final class ProseTests: XCTestCase {
    func testSplitsCodeSpans() {
        let segments = DeskProse.segments("swaps `jsonwebtoken` for `jose`, which runs")

        XCTAssertEqual(segments.map(\.text), ["swaps ", "jsonwebtoken", " for ", "jose", ", which runs"])
        XCTAssertEqual(segments.map(\.isCode), [false, true, false, true, false])
    }

    func testReadsADescription() {
        let body = """
        <!-- template: describe your change -->
        Moves `middleware/auth.ts` to the edge
        runtime.

        - swaps a library
        - caches **sessions** for 60s

        ## Testing

        Passes [locally](https://example.com).
        """

        let blocks = DeskProse.blocks(body)

        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .item, .item, .heading, .paragraph])
        XCTAssertEqual(blocks[0].text, "Moves `middleware/auth.ts` to the edge runtime.")
        XCTAssertEqual(blocks[2].text, "caches sessions for 60s")
        XCTAssertEqual(blocks[3].text, "Testing")
        XCTAssertEqual(blocks[4].text, "Passes locally.")
    }

    /// Dependabot writes HTML inside markdown, with the release notes,
    /// changelog and commits in collapsed <details> sections.
    func testReadsADependabotDescription() {
        let body = """
        Bumps the bundler-minor group with 1 update: [faraday](https://github.com/lostisland/faraday).

        Updates `faraday` from 2.14.4 to 2.15.0
        <details>
        <summary>Release notes</summary>
        <p><em>Sourced from <a href="https://github.com/lostisland/faraday/releases">faraday's releases</a>.</em></p>
        <blockquote>
        <h2>What's Changed</h2>
        <ul>
        <li>Fix typo in <code>Faraday::Connection#options</code> doc by <a href="https://github.com/Bo98"><code>@Bo98</code></a> in <a href="https://redirect.github.com/lostisland/faraday/pull/1674">lostisland/faraday#1674</a></li>
        <li>gemspec: Relax faraday-net_http to &lt; 3.6</li>
        </ul>
        </blockquote>
        </details>
        [![Dependabot compatibility score](https://dependabot-badges.githubapp.com/badges/compatibility_score?dependency-name=faraday)](https://docs.github.com/en/github/managing-security-vulnerabilities/about-dependabot-security-updates#about-compatibility-scores)

        [//]: # (dependabot-automerge-start)
        [//]: # (dependabot-automerge-end)

        <details>
        <summary>Dependabot commands and options</summary>
        <br />

        - `@dependabot ignore <dependency name> minor version` will close this group update PR
        </details>
        """

        let blocks = DeskProse.blocks(body)

        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph, .details, .details])
        XCTAssertEqual(blocks[0].text, "Bumps the bundler-minor group with 1 update: faraday.")
        XCTAssertEqual(blocks[2].text, "Release notes")
        let notes = blocks[2].children
        XCTAssertEqual(notes.map(\.kind), [.paragraph, .heading, .item, .item])
        XCTAssertEqual(notes[0].text, "Sourced from faraday's releases.")
        XCTAssertEqual(notes[1].text, "What's Changed")
        XCTAssertEqual(notes[2].text, "Fix typo in `Faraday::Connection#options` doc by `@Bo98` in lostisland/faraday#1674")
        XCTAssertEqual(notes[3].text, "gemspec: Relax faraday-net_http to < 3.6")
        XCTAssertEqual(blocks[3].children.first?.text, "`@dependabot ignore <dependency name> minor version` will close this group update PR")
        XCTAssertFalse(blocks.flatMap { [$0.text] + $0.children.map(\.text) }.contains { $0.contains("<a ") || $0.contains("</") })
    }
}

final class AgoTests: XCTestCase {
    func testShortForm() {
        let now = Date()
        XCTAssertEqual(Ago.short(now.addingTimeInterval(-20 * 60), now: now), "20m")
        XCTAssertEqual(Ago.short(now.addingTimeInterval(-5 * 3600), now: now), "5h")
        XCTAssertEqual(Ago.short(now.addingTimeInterval(-3 * 86400), now: now), "3d")
    }

    func testLongForm() {
        let now = Date()
        XCTAssertEqual(Ago.long(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(Ago.long(now.addingTimeInterval(-120), now: now), "2 min ago")
    }
}

@MainActor
final class ReviewTests: XCTestCase {
    func testDecodesWhatClaudeSendsBack() throws {
        let json = """
        {"summary":"The switch to `jose` looks right.","comments":[
          {"severity":"should fix","file":"middleware/auth.ts","lines":"L37–40","title":"No algorithm allowlist on verify",
           "body":"Pass `{ algorithms: ['RS256'] }`.","code":[{"no":38,"mark":"+","text":"  const { payload } = await jwtVerify(token, key);"}],
           "highlight":[38],"context":[],"asks":["is this exploitable in practice?","show me the fixed call"]}]}
        """

        let review = try JSONDecoder().decode(Review.self, from: Data(json.utf8))

        XCTAssertEqual(review.comments.first?.severity, .shouldFix)
        XCTAssertEqual(review.comments.first?.asks.count, 2)
        XCTAssertEqual(review.filesRead, 0)
        XCTAssertNil(review.verdict)
    }

    func testDecodesTheVerdict() throws {
        let json = #"{"summary":"Fine.","comments":[],"verdict":"hold","reason":"The cache never expires."}"#

        let review = try JSONDecoder().decode(Review.self, from: Data(json.utf8))

        XCTAssertEqual(review.verdict, .hold)
        XCTAssertEqual(review.reason, "The cache never expires.")
    }

    func testTheSchemaAsksForAVerdict() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ReviewStore.firstPassSchema.utf8)) as? [String: Any])

        XCTAssertEqual(schema["required"] as? [String], ["summary", "comments", "verdict", "reason", "focus"])
    }

    func testACommentCopiesAsAFixPrompt() {
        let pr = DeskPullRequest(repo: "acme/api", number: 7, title: "Cache", url: "https://github.com/acme/api/pull/7", body: "",
                             author: "jlee", reviewers: [], checks: .passing, status: .review, additions: 1, deletions: 0,
                             changedFiles: 1, updatedAt: Date(), headRef: "jlee/cache", baseRef: "main", headSha: "abc")
        let comment = ReviewComment(severity: .blocking, file: "lib/cache.ts", lines: "L3", title: "Never expires",
                                    body: "Entries live forever.", code: [CodeLine(no: 3, mark: "+", text: "const cache = new Map();")],
                                    highlight: [3], context: [], asks: [])
        let thread = [ChatMessage(role: .user, text: "fix?"), ChatMessage(role: .assistant, text: "Add a TTL."),
                      ChatMessage(role: .error, text: "couldn't reach claude. try again?")]

        XCTAssertEqual(FixPrompt.comment(comment, thread: thread, pr: pr), """
        Fix this review feedback on https://github.com/acme/api/pull/7 (acme/api#7, "Cache"), branch `jlee/cache` into `main`.

        ## [blocking] Never expires — lib/cache.ts L3

        Entries live forever.

        ```
        3 + const cache = new Map();
        ```

        Discussion about this comment:
        Developer: fix?
        Reviewer: Add a TTL.
        """)
    }

    func testTheReviewPromptFillsInThePullRequest() {
        let pr = DeskPullRequest(repo: "acme/api", number: 7, title: "Cache", url: "https://github.com/acme/api/pull/7", body: "",
                             author: "jlee", reviewers: [], checks: .passing, status: .review, additions: 1, deletions: 0,
                             changedFiles: 1, updatedAt: Date(), headRef: "jlee/cache", baseRef: "main", headSha: "abc")

        XCTAssertEqual(ReviewStore.reviewPrompt(pr, template: "check {ref} ({title}) by {author}: gh pr diff {number} --repo {repo} at {sha}, {head} → {base}"),
                       "check acme/api#7 (Cache) by jlee: gh pr diff 7 --repo acme/api at abc, jlee/cache → main")
        let full = ReviewStore.reviewPrompt(pr)
        XCTAssertTrue(full.hasPrefix("Review https://github.com/acme/api/pull/7 (acme/api#7, \"Cache\") by jlee, merging jlee/cache into main at commit abc."))
        XCTAssertFalse(full.contains("{"), "every placeholder in the default is filled")
    }

    func testAnEditedPromptIsKeptAndTheDefaultIsNot() {
        let defaults = UserDefaults(suiteName: "prompt-\(UUID())")!
        let settings = DeskSettings(defaults: defaults)

        settings.reviewPrompt = "be brief about {ref}"
        XCTAssertEqual(DeskSettings(defaults: defaults).reviewPrompt, "be brief about {ref}")
        settings.reviewPrompt = ""
        XCTAssertEqual(settings.reviewTemplate, ReviewStore.defaultReviewPrompt, "an emptied prompt means the default")
        XCTAssertTrue(DeskSettings(defaults: defaults).reviewPromptIsDefault)
    }

    func testTheReviewerCanBeRenamed() {
        let settings = DeskSettings(defaults: UserDefaults(suiteName: "name-\(UUID())")!)
        XCTAssertEqual(settings.agent, "claude")
        settings.agentName = "  tanuki "
        XCTAssertEqual(settings.agent, "tanuki")
        XCTAssertEqual(ApproveButton.warning(record: nil, outdated: false, agent: settings.agent),
                       "tanuki hasn't reviewed this yet. this posts an approval to github as you.")
    }

    func testTheApproveDialogSaysWhatClaudeThinks() {
        var review = Review(summary: "", comments: [], verdict: .hold, reason: "The cache never expires.")
        review.headSha = "old"

        XCTAssertEqual(ApproveButton.warning(record: nil, outdated: false),
                       "claude hasn't reviewed this yet. this posts an approval to github as you.")
        XCTAssertEqual(ApproveButton.warning(record: ReviewRecord(review: review), outdated: true),
                       "claude's review is of an older commit.\n\nclaude says hold off: The cache never expires.\n\nthis posts an approval to github as you.")
    }

    func testMetaLine() {
        var review = Review(summary: "", comments: [])
        review.filesRead = 4
        review.contextFiles = 3
        review.seconds = 41

        XCTAssertEqual(review.meta, "read 4 changed files · pulled context from 3 more · 41s")
    }

    func testAFollowUpCarriesTheConversation() {
        let thread = [
            ChatMessage(role: .user, text: "why does a warm isolate matter?"),
            ChatMessage(role: .assistant, text: "They're stateless between deploys."),
            ChatMessage(role: .user, text: "how would you fix this?")
        ]

        let prompt = ReviewStore.chatPrompt(thread)

        XCTAssertTrue(prompt.contains("Developer: why does a warm isolate matter?"))
        XCTAssertTrue(prompt.contains("You: They're stateless between deploys."))
        XCTAssertTrue(prompt.hasSuffix("The developer now asks: how would you fix this?"))
    }

    func testStrayMarkdownIsFlattened() {
        XCTAssertEqual(ReviewStore.plain("**Yes.** Use\n```ts\nfoo()\n```"), "Yes. Use\n`foo()\n`")
    }
}

@MainActor
final class BackgroundReviewTests: XCTestCase {
    private func pr(_ number: Int, sha: String, status: DeskPullRequest.Status = .review) -> DeskPullRequest {
        DeskPullRequest(repo: "acme/api", number: number, title: "t", url: "", body: "", author: "jlee", reviewers: [],
                    checks: .passing, status: status, additions: 1, deletions: 1, changedFiles: 1,
                    updatedAt: Date(), headRef: "f", baseRef: "main", headSha: sha)
    }

    /// A store holding one finished review, of acme/api#1 at commit "a".
    private func store(autoReview: Bool = true) throws -> ReviewStore {
        let settings = DeskSettings(defaults: UserDefaults(suiteName: "bg-\(UUID())")!)
        settings.autoReview = autoReview
        var review = Review(summary: "ok", comments: [], verdict: .approve, reason: "fine")
        review.headSha = "a"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID()).json")
        try JSONEncoder().encode(["acme/api#1": ReviewRecord(review: review)]).write(to: file)
        return ReviewStore(settings: settings, file: file)
    }

    func testAReviewOfAnOlderCommitIsOutOfDate() throws {
        let reviews = try store()

        XCTAssertFalse(reviews.isOutdated(pr(1, sha: "a")))
        XCTAssertTrue(reviews.isOutdated(pr(1, sha: "b")))
        XCTAssertFalse(reviews.isOutdated(pr(2, sha: "a")), "no review, nothing to be out of date")
    }

    func testOnlyNewOrUpdatedRequestsAreQueued() throws {
        let reviews = try store()

        XCTAssertFalse(reviews.needsBackgroundReview(pr(1, sha: "a")), "already reviewed at this commit")
        XCTAssertTrue(reviews.needsBackgroundReview(pr(1, sha: "b")), "new commits")
        XCTAssertTrue(reviews.needsBackgroundReview(pr(2, sha: "c")), "never reviewed")
        XCTAssertFalse(reviews.needsBackgroundReview(pr(3, sha: "d", status: .draft)), "drafts wait")
        XCTAssertFalse(reviews.needsBackgroundReview(pr(4, sha: "")), "no commit to pin the review to")
    }
}
