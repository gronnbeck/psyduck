import XCTest
@testable import Psyduck

@MainActor
final class ReviewAgentsTests: XCTestCase {
    private let pr = DeskPullRequest(repo: "acme/api", number: 7, title: "Cache", url: "https://github.com/acme/api/pull/7", body: "",
                                 author: "jlee", reviewers: [], checks: .passing, status: .review, additions: 1, deletions: 0,
                                 changedFiles: 1, updatedAt: Date(), headRef: "jlee/cache", baseRef: "main", headSha: "abc")

    private func comment(_ title: String, _ severity: ReviewComment.Severity = .shouldFix, file: String = "lib/cache.ts") -> ReviewComment {
        ReviewComment(severity: severity, file: file, lines: "L3", title: title, body: "b",
                      code: [], highlight: [], context: [], asks: [])
    }

    private func firstPass(_ verdict: Review.Verdict, reason: String = "first reason") -> FirstPass {
        let json = #"{"summary":"s","comments":[],"verdict":"\#(verdict.rawValue)","reason":"\#(reason)","focus":[]}"#
        return try! JSONDecoder().decode(FirstPass.self, from: Data(json.utf8))
    }

    func testEverySchemaIsValidJSON() throws {
        for schema in [ReviewStore.firstPassSchema, ReviewStore.findingsSchema, ReviewStore.verifySchema] {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(schema.utf8)))
        }
    }

    func testFindingsAreCheckedOneFilePerAgent() {
        let findings = [Finding(comment: comment("a"), by: "first pass"),
                        Finding(comment: comment("b", file: "x.ts"), by: "security"),
                        Finding(comment: comment("c"), by: "tests")]

        let groups = Finding.byFile(findings)

        XCTAssertEqual(groups.map { $0.map(\.comment.title) }, [["a", "c"], ["b"]])
    }

    func testACheckerMergesAndDrops() throws {
        let findings = [Finding(comment: comment("cache never expires"), by: "first pass"),
                        Finding(comment: comment("unbounded map"), by: "performance"),
                        Finding(comment: comment("naming"), by: "code style")]
        let output = #"""
        {"comments":[{"severity":"blocking","file":"lib/cache.ts","lines":"L3","title":"cache grows forever","body":"b",
          "code":[],"highlight":[],"context":[],"asks":[],"merged":[0,1,9]}],
         "dropped":[{"finding":2,"why":"matches the file's style"},{"finding":7,"why":"no such finding"}]}
        """#

        let result = try ReviewStore.checked(findings, output: Data(output.utf8))

        XCTAssertEqual(result.kept.map(\.title), ["cache grows forever"])
        XCTAssertEqual(result.kept[0].foundBy, ["first pass", "performance"])
        XCTAssertEqual(result.dropped, [DroppedFinding(title: "naming", file: "lib/cache.ts", by: "code style", why: "matches the file's style")])
    }

    func testTheCallFollowsWhatHeldUp() {
        XCTAssertEqual(ReviewStore.verdict([comment("nit", .nit)], first: firstPass(.approve)).0, .approve)
        XCTAssertEqual(ReviewStore.verdict([comment("nit", .nit)], first: firstPass(.approve)).1, "first reason",
                       "the first pass's reason stands when the call agrees")

        let hold = ReviewStore.verdict([comment("leak", .blocking), comment("nit", .nit)], first: firstPass(.approve))
        XCTAssertEqual(hold.0, .hold)
        XCTAssertEqual(hold.1, "fix first: leak.")

        let cleared = ReviewStore.verdict([], first: firstPass(.hold))
        XCTAssertEqual(cleared.0, .approve)
        XCTAssertTrue(cleared.1.contains("didn't hold up"))
    }

    func testMostSeriousFirst() {
        let ordered = ReviewStore.ordered([comment("n", .nit), comment("s1"), comment("b", .blocking), comment("s2")])

        XCTAssertEqual(ordered.map(\.title), ["b", "s1", "s2", "n"])
    }

    func testTheFirstPassPromptAsksForFocusAndNamesTheSpecialists() {
        let prompt = ReviewStore.firstPassPrompt(pr, template: "Review {ref}.", specialists: Array(Specialist.all.prefix(2)))

        XCTAssertTrue(prompt.hasPrefix("Review acme/api#7."))
        XCTAssertTrue(prompt.contains("In focus, list up to 4"))
        XCTAssertTrue(prompt.contains("correctness, security"))
    }

    func testASpecialistStaysInItsLane() {
        let style = Specialist.all.first { $0.id == "style" }!
        let prompt = ReviewStore.specialistPrompt(pr, style)

        XCTAssertTrue(prompt.contains("you look only at code style"))
        XCTAssertTrue(prompt.contains("gh pr diff 7 --repo acme/api"))
        XCTAssertTrue(prompt.contains("contents/PATH?ref=abc"))
    }

    func testEveryAgentIsAskedForShortCommentsWithFixes() {
        let prompts = [
            ReviewStore.firstPassPrompt(pr, template: "Review {ref}.", specialists: []),
            ReviewStore.specialistPrompt(pr, Specialist.all[0]),
            ReviewStore.verifyPrompt(pr, [Finding(comment: comment("Never expires"), by: "security")]),
        ]
        for prompt in prompts {
            XCTAssertTrue(prompt.contains("One problem per comment"))
            XCTAssertTrue(prompt.contains("fixes: one to three"))
        }
        XCTAssertTrue(ReviewStore.findingsSchema.contains(#""fixes""#))
    }

    func testACommentReadsAsProblemThenFixes() throws {
        var c = comment("Never expires")
        XCTAssertEqual(c.plain, "Never expires. b")
        c.fixes = ["Add a TTL."]
        XCTAssertEqual(c.plain, "Never expires. b Fix: Add a TTL.")
        c.fixes = ["Add a TTL.", "Drop the cache."]
        XCTAssertEqual(c.plain, "Never expires. b Possible fixes: (1) Add a TTL. (2) Drop the cache.")

        // Saved reviews from before fixes still load.
        let old = #"{"severity":"nit","file":"a","lines":"L1","title":"t","body":"b","code":[],"highlight":[],"context":[],"asks":[]}"#
        XCTAssertNil(try JSONDecoder().decode(ReviewComment.self, from: Data(old.utf8)).fixes)
    }

    func testMetaCountsAgentsAndWhatWasKept() {
        var review = Review(summary: "", comments: [comment("a")])
        review.filesRead = 4
        review.agents = 9
        review.raised = 8
        review.seconds = 80

        XCTAssertEqual(review.meta, "read 4 changed files · 9 agents · kept 1 of 8 findings · 80s")
    }

    func testPipelineSettingsAreKept() {
        let suite = "agents-\(UUID())"
        let settings = DeskSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(settings.model(.firstPass), "sonnet")
        XCTAssertEqual(settings.model(.verify), "")
        XCTAssertEqual(settings.agentLimit, 4)
        XCTAssertEqual(settings.specialists.count, Specialist.all.count)

        settings.stageModels[.verify] = "opus"
        settings.maxAgents = 0
        settings.specialistsOff = ["style"]

        let again = DeskSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(again.model(.verify), "opus")
        XCTAssertNil(again.agentLimit, "0 is unlimited")
        XCTAssertFalse(again.specialists.contains { $0.id == "style" })
    }
}

@MainActor
final class AgentLimiterTests: XCTestCase {
    func testAgentsWaitForASlot() async throws {
        var limit: Int? = 2
        let limiter = AgentLimiter { limit }
        try await limiter.acquire()
        try await limiter.acquire()

        var third = false
        let waiting = Task { @MainActor in
            try await limiter.acquire()
            third = true
        }
        await Task.yield()
        XCTAssertFalse(third)

        limiter.release()
        try await waiting.value
        XCTAssertTrue(third)
        XCTAssertEqual(limiter.running, 2)

        limit = nil
        try await limiter.acquire()
        XCTAssertEqual(limiter.running, 3, "unlimited never waits")
    }

    func testARaisedLimitLetsWaitersGo() async throws {
        var limit: Int? = 1
        let limiter = AgentLimiter { limit }
        try await limiter.acquire()
        let waiting = Task { @MainActor in try await limiter.acquire() }
        await Task.yield()

        limit = 2
        limiter.pump()
        try await waiting.value
        XCTAssertEqual(limiter.running, 2)
    }

    func testACancelledWaiterGivesItsSlotBack() async throws {
        let limiter = AgentLimiter { 1 }
        try await limiter.acquire()
        let waiting = Task { @MainActor in try await limiter.acquire() }
        await Task.yield()

        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("should have been cancelled")
        } catch is CancellationError {}
        XCTAssertEqual(limiter.running, 1)
    }
}

@MainActor
final class ApproveAllTests: XCTestCase {
    private func pr(_ number: Int, sha: String = "a", checks: DeskPullRequest.Checks = .passing,
                    status: DeskPullRequest.Status = .review, approved: String? = nil) -> DeskPullRequest {
        var pr = DeskPullRequest(repo: "acme/api", number: number, title: "t\(number)", url: "", body: "", author: "jlee", reviewers: [],
                             checks: checks, status: status, additions: 1, deletions: 1, changedFiles: 1,
                             updatedAt: Date(), headRef: "f", baseRef: "main", headSha: sha)
        pr.approvedSha = approved
        return pr
    }

    func testOnlyCurrentApprovalsWithNothingFailing() throws {
        let settings = DeskSettings(defaults: UserDefaults(suiteName: "all-\(UUID())")!)
        func record(_ verdict: Review.Verdict, sha: String = "a") -> ReviewRecord {
            var review = Review(summary: "", comments: [], verdict: verdict, reason: "")
            review.headSha = sha
            return ReviewRecord(review: review)
        }
        let records = (1...7).reduce(into: [String: ReviewRecord]()) { $0["acme/api#\($1)"] = record(.approve) }
            .merging(["acme/api#2": record(.hold), "acme/api#3": record(.approve, sha: "old")]) { $1 }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("all-\(UUID()).json")
        try JSONEncoder().encode(records).write(to: file)
        let reviews = ReviewStore(settings: settings, file: file)
        let prs = PRStore(settings: settings)
        let list = [pr(1), pr(2), pr(3), pr(4, checks: .failing), pr(5, checks: .pending),
                    pr(6, status: .draft), pr(7, approved: "a"), pr(8)]
        prs.lists = PRLists(review: list, mine: [])

        let eligible = ApproveAllMenu.eligible(list, prs: prs, reviews: reviews)

        XCTAssertEqual(eligible.map(\.number), [1],
                       "2 says hold, 3's review is old, 4 fails, 5 is still running checks, 6 is a draft, 7 is approved, 8 has no review")
        XCTAssertEqual(ApproveAllMenu.leftOut(list, prs: prs, reviews: reviews).map { "\($0.0.number) \($0.1)" },
                       ["3 review is of an older commit", "4 checks failing", "5 checks still running", "6 draft"])
        XCTAssertTrue(ApproveAllMenu.summary(eligible, agent: "tanuki").hasPrefix("tanuki would approve each of these:\nacme/api#1 — t1"))
    }
}
