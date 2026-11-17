import XCTest
@testable import Psyduck

final class DiffLinesTests: XCTestCase {
    static let diff = """
    diff --git a/middleware/auth.ts b/middleware/auth.ts
    index 1111111..2222222 100644
    --- a/middleware/auth.ts
    +++ b/middleware/auth.ts
    @@ -20,4 +20,6 @@ import { jwtVerify } from 'jose';
     const key = loadKey();
    -const cache = {};
    +const sessionCache = new Map<string, Session>();
    +
     export async function middleware(req: NextRequest) {
    +  const cached = sessionCache.get(token);
       const token = req.cookies.get('session');
    diff --git a/old.ts b/old.ts
    deleted file mode 100644
    --- a/old.ts
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -export const a = 1;
    --- a comment that looks like a header
    """

    func testKnowsWhichLinesCanTakeAComment() {
        let lines = DraftDiffLines.parse(Self.diff)

        XCTAssertTrue(lines.contains("middleware/auth.ts", "RIGHT", 20), "unchanged line, new side")
        XCTAssertTrue(lines.contains("middleware/auth.ts", "LEFT", 21), "removed line")
        XCTAssertTrue(lines.contains("middleware/auth.ts", "RIGHT", 21), "added line")
        XCTAssertTrue(lines.contains("middleware/auth.ts", "RIGHT", 24))
        XCTAssertFalse(lines.contains("middleware/auth.ts", "RIGHT", 40), "outside every hunk")
        XCTAssertTrue(lines.contains("old.ts", "LEFT", 2), "a removed line starting with -- isn't a header")
        XCTAssertFalse(lines.contains("lib/session.ts", "RIGHT", 31), "a file the PR doesn't touch")
    }

    private func comment(_ file: String, code: [CodeLine], highlight: [Int]) -> ReviewComment {
        ReviewComment(severity: .blocking, file: file, lines: "L20–24", title: "t", body: "b",
                      code: code, highlight: highlight, context: [], asks: [])
    }

    func testPinsAHighlightedRange() throws {
        let lines = DraftDiffLines.parse(Self.diff)
        let c = comment("middleware/auth.ts", code: [CodeLine(no: 21, mark: "+", text: ""), CodeLine(no: 23, mark: " ", text: ""), CodeLine(no: 24, mark: "+", text: "")],
                        highlight: [21, 24])

        let anchor = try XCTUnwrap(lines.anchor(c))

        XCTAssertEqual(anchor.line, 24)
        XCTAssertEqual(anchor.start, 21)
        XCTAssertEqual(anchor.side, "RIGHT")
    }

    func testARemovedLineGoesOnTheLeft() throws {
        let c = comment("middleware/auth.ts", code: [CodeLine(no: 21, mark: "-", text: "const cache = {};")], highlight: [21])

        let anchor = try XCTUnwrap(DraftDiffLines.parse(Self.diff).anchor(c))

        XCTAssertEqual(anchor.side, "LEFT")
        XCTAssertNil(anchor.start)
    }

    func testFallsBackToAnyLineOnTheDiff() throws {
        let c = comment("middleware/auth.ts", code: [CodeLine(no: 22, mark: "+", text: ""), CodeLine(no: 40, mark: " ", text: "")], highlight: [40])

        XCTAssertEqual(DraftDiffLines.parse(Self.diff).anchor(c)?.line, 22)
    }

    func testACommentOffTheDiffHasNoAnchor() {
        let c = comment("lib/session.ts", code: [CodeLine(no: 31, mark: " ", text: "")], highlight: [31])

        XCTAssertNil(DraftDiffLines.parse(Self.diff).anchor(c))
    }
}

@MainActor
final class DraftTests: XCTestCase {
    private func record(verdict: Review.Verdict, severity: ReviewComment.Severity = .blocking) -> ReviewRecord {
        var review = Review(summary: "Looks right apart from the cache.", comments: [
            ReviewComment(severity: severity, file: "middleware/auth.ts", lines: "L21–24", title: "Cache never expires",
                          body: "Entries live forever.", code: [CodeLine(no: 21, mark: "+", text: ""), CodeLine(no: 24, mark: "+", text: "")],
                          highlight: [21, 24], context: [], asks: []),
            ReviewComment(severity: .nit, file: "lib/session.ts", lines: "L31", title: "Unused import",
                          body: "Nothing uses it.", code: [CodeLine(no: 31, mark: " ", text: "")], highlight: [31], context: [], asks: [])
        ], verdict: verdict, reason: "r")
        review.headSha = "abc"
        return ReviewRecord(review: review)
    }

    func testTheSeedPinsCommentsAndPicksTheEvent() {
        let diff = DraftDiffLines.parse(DiffLinesTests.diff)

        let draft = DraftStore.seed(record(verdict: .hold), diff: diff, mine: false)

        XCTAssertEqual(draft.event, .requestChanges, "a hold with a blocking comment")
        XCTAssertEqual(draft.sha, "abc")
        XCTAssertEqual(draft.body, "Looks right apart from the cache.")
        XCTAssertEqual(draft.comments[0].line, 24)
        XCTAssertEqual(draft.comments[0].startLine, 21)
        XCTAssertFalse(draft.comments[1].onDiff)
        XCTAssertEqual(DraftStore.seed(record(verdict: .approve, severity: .nit), diff: diff, mine: false).event, .approve)
        XCTAssertEqual(DraftStore.seed(record(verdict: .hold), diff: diff, mine: true).event, .comment, "you can't request changes on your own PR")
    }

    func testThePayloadPinsWhatItCanAndFoldsTheRestIntoTheBody() {
        var draft = DraftStore.seed(record(verdict: .hold), diff: DraftDiffLines.parse(DiffLinesTests.diff), mine: false)
        draft.comments[0].body = "Could these expire after 60s?"
        draft.comments[1].body = "This import isn't used."

        let payload = draft.payload

        XCTAssertEqual(payload.commit_id, "abc")
        XCTAssertEqual(payload.event, "REQUEST_CHANGES")
        XCTAssertEqual(payload.comments, [.init(path: "middleware/auth.ts", body: "Could these expire after 60s?", line: 24, side: "RIGHT", start_line: 21, start_side: "RIGHT")])
        XCTAssertEqual(payload.body, "Looks right apart from the cache.\n\n---\n\n**`lib/session.ts` L31**\n\nThis import isn't used.")

        draft.comments[1].include = false
        XCTAssertEqual(draft.payload.body, "Looks right apart from the cache.", "left-out comments go nowhere")
    }

    func testOnlyAnApprovalCanGoWithoutAComment() {
        var draft = ReviewDraft(body: "", event: .comment, comments: [], sha: "abc")
        XCTAssertTrue(draft.missingBody)
        draft.event = .approve
        XCTAssertFalse(draft.missingBody)
    }

    func testClaudesEditsChangeTextButNeverWhereACommentSits() {
        var draft = DraftStore.seed(record(verdict: .hold), diff: DraftDiffLines.parse(DiffLinesTests.diff), mine: true)
        let answer: [String: Any] = [
            "body": "Nice work.", "event": "approve",
            "comments": [["id": "0", "body": "Friendlier.", "include": true, "line": 99], ["id": "1", "body": "", "include": false], ["id": "7", "body": "x", "include": true]]
        ]

        DraftStore.apply(answer, to: &draft, byIndex: false, mine: true)

        XCTAssertEqual(draft.body, "Nice work.")
        XCTAssertEqual(draft.event, .comment, "your own PR can only get a comment")
        XCTAssertEqual(draft.comments[0].body, "Friendlier.")
        XCTAssertEqual(draft.comments[0].line, 24)
        XCTAssertFalse(draft.comments[1].include)
        XCTAssertEqual(draft.comments[1].body, "Unused import. Nothing uses it.", "an empty rewrite keeps the text")
        XCTAssertEqual(draft.comments.count, 2)
    }

    func testTheToneOfVoiceGoesIntoBothPrompts() {
        let pr = DeskPullRequest(repo: "acme/api", number: 7, title: "Cache", url: "", body: "", author: "jlee", reviewers: [],
                             checks: .passing, status: .review, additions: 1, deletions: 0, changedFiles: 1, updatedAt: Date(),
                             headRef: "f", baseRef: "main", headSha: "abc")
        let draft = ReviewDraft(body: "hi", event: .comment, comments: [], sha: "abc", chat: [ChatMessage(role: .user, text: "shorter")])
        let tone = "casual, lowercase, ask questions"

        XCTAssertTrue(DraftStore.draftPrompt(pr, record(verdict: .hold), tone: tone).contains("follow it over the above where they differ:\n" + tone))
        XCTAssertTrue(DraftStore.editPrompt(pr, draft, tone: tone).contains(tone))
        XCTAssertEqual(DraftStore.voice("  "), DraftStore.baseVoice, "no guidance, just the default")
    }

    func testPostedReviewsAreKeptInTheHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID()).jsonl")
        let pr = DeskPullRequest(repo: "acme/api", number: 7, title: "Cache", url: "https://github.com/acme/api/pull/7", body: "", author: "jlee",
                             reviewers: [], checks: .passing, status: .review, additions: 1, deletions: 0, changedFiles: 1,
                             updatedAt: Date(), headRef: "f", baseRef: "main", headSha: "abc")
        var draft = DraftStore.seed(record(verdict: .hold), diff: DraftDiffLines.parse(DiffLinesTests.diff), mine: false)
        draft.draftedBody = draft.body
        draft.comments[0].drafted = "Please fix this cache."
        draft.comments[0].body = "could this cache expire?"
        draft.chat = [ChatMessage(role: .user, text: "more casual")]
        draft.postedAt = Date(timeIntervalSince1970: 1_800_000_000)
        draft.postedURL = "https://github.com/acme/api/pull/7#pullrequestreview-1"

        DraftStore.append(PostedReview(pr, draft, tone: "casual"), to: url)
        DraftStore.append(PostedReview(pr, draft, tone: "casual"), to: url)

        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "appended, never overwritten")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(PostedReview.self, from: Data(lines[0].utf8))
        XCTAssertEqual(entry.pr, "acme/api#7")
        XCTAssertEqual(entry.tone, "casual")
        XCTAssertEqual(entry.draft.comments[0].drafted, "Please fix this cache.")
        XCTAssertEqual(entry.draft.comments[0].body, "could this cache expire?")
        XCTAssertEqual(entry.draft.chat.first?.text, "more casual")
    }

    func testTheGitHubErrorIsReadable() {
        let result = CommandResult(status: 1, stdout: #"{"message":"Unprocessable Entity","errors":["Line could not be resolved"]}"#, stderr: "gh: Unprocessable Entity (HTTP 422)")

        XCTAssertEqual(DraftStore.apiError(result), "Unprocessable Entity — Line could not be resolved")
    }

    func testDraftsAreKept() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID()).json")
        let draft = ReviewDraft(body: "hi", event: .comment, comments: [], sha: "abc")
        try JSONEncoder().encode(["acme/api#1": draft]).write(to: file)

        let store = DraftStore(settings: DeskSettings(defaults: UserDefaults(suiteName: "d-\(UUID())")!), file: file)

        XCTAssertEqual(store.drafts["acme/api#1"], draft)
    }
}
