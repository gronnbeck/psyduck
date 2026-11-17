import SwiftUI
import XCTest
@testable import Psyduck

/// Renders every screen with the design's sample data and writes PNGs, for
/// looking at the app without a Screen Recording permission. Skipped unless
/// PSYDUCK_DESK_RENDER_DIR is set:
///
///   TEST_RUNNER_PSYDUCK_DESK_RENDER_DIR=/tmp/screens xcodebuild test -scheme Psyduck \
///     -destination 'platform=macOS' -only-testing:PsyduckTests/DeskScreenRenderTests
@MainActor
final class DeskScreenRenderTests: XCTestCase {
    func testRenderEveryScreen() async throws {
        let dir = ProcessInfo.processInfo.environment["PSYDUCK_DESK_RENDER_DIR"] ?? ""
        try XCTSkipIf(dir.isEmpty, "set PSYDUCK_DESK_RENDER_DIR to render screens")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let settings = DeskSettings(defaults: UserDefaults(suiteName: "render-\(UUID())")!)
        let app = DeskModel()
        let prs = PRStore(settings: settings)
        let updater = UpdaterModel(info: ["SUFeedURL": ""])

        let now = Date()
        func pr(_ repo: String, _ n: Int, _ title: String, _ author: String, _ checks: DeskPullRequest.Checks,
                _ status: DeskPullRequest.Status, _ add: Int, _ del: Int, hours: Double, reviewers: [String] = [],
                body: String = "", files: Int = 3, branch: String = "feature") -> DeskPullRequest {
            DeskPullRequest(repo: repo, number: n, title: title, url: "https://github.com/\(repo)/pull/\(n)", body: body,
                        author: author, reviewers: reviewers, checks: checks, status: status, additions: add,
                        deletions: del, changedFiles: files, updatedAt: now.addingTimeInterval(-hours * 3600),
                        headRef: branch, baseRef: "main", headSha: "abc")
        }
        let edge = pr("acme/web-app", 1482, "Migrate auth middleware to the edge runtime", "mkato", .passing, .review, 312, 88, hours: 2,
                      body: """
                      Moves `middleware/auth.ts` from the Node runtime to the edge runtime so session checks run before a request reaches the origin.

                      - swaps `jsonwebtoken` for `jose`, which runs on the edge
                      - reads the public key from `JWT_PUBLIC_KEY` instead of the filesystem
                      - caches decoded sessions in memory for 60s

                      ## Testing

                      The auth e2e suite passes locally. I haven't tested token refresh against staging yet.
                      """, files: 4, branch: "mkato/edge-auth")
        prs.lists = PRLists(
            review: [
                edge,
                pr("acme/api", 903, "Add rate limiting to /v2/search", "jlee", .pending, .review, 146, 12, hours: 5),
                pr("np-lol/pin", 57, "Fix timezone drift in recurring reminders", "sora", .failing, .review, 41, 19, hours: 26),
                pr("acme/infra", 221, "Bump terraform aws provider to 6.x", "dependabot", .passing, .review, 8, 8, hours: 75)
            ],
            mine: [
                pr("np-lol/desk", 12, "PR list: read gh path from settings", "you", .pending, .draft, 204, 31, hours: 0.34),
                pr("acme/web-app", 1477, "Replace moment with date-fns", "you", .passing, .changes, 530, 611, hours: 26, reviewers: ["mkato", "jlee"]),
                pr("acme/api", 899, "Cache user settings in redis", "you", .passing, .approved, 97, 14, hours: 50, reviewers: ["jlee"])
            ])
        prs.syncedAt = now.addingTimeInterval(-120)

        // A finished review of #1482, loaded the way a saved one would be.
        var review = Review(summary: "The switch to `jose` looks right and the e2e coverage is good. The session cache is the real problem: it ignores both expiry and revocation.", comments: [
            ReviewComment(severity: .blocking, file: "middleware/auth.ts", lines: "L20–29", title: "Session cache never expires",
                          body: "Entries are never evicted, so a revoked token keeps passing this check for as long as the isolate stays warm — often hours.",
                          fixes: ["Store `expiresAt` with each entry and skip stale ones.", "Drop the cache and verify every request — `jose` is fast enough."],
                          code: [CodeLine(no: 23, mark: "+", text: "const sessionCache = new Map<string, Session>();"),
                                 CodeLine(no: 24, mark: "+", text: ""),
                                 CodeLine(no: 25, mark: "+", text: "export async function middleware(req: NextRequest) {"),
                                 CodeLine(no: 28, mark: "+", text: "  const cached = sessionCache.get(token);")],
                          highlight: [23, 28],
                          context: [ContextSnippet(why: "`revokeSession()` only deletes the database row. It can't reach this cache.", file: "lib/session.ts", lines: "L31–34", tag: "unchanged in this PR",
                                                   code: [CodeLine(no: 31, mark: " ", text: "export async function revokeSession(id: string) {"),
                                                          CodeLine(no: 32, mark: " ", text: "  await db.session.delete({ where: { id } });")], highlight: [32])],
                          asks: ["how would you fix this?", "is 60s even short enough for sign-out?"],
                          foundBy: ["first pass", "security", "digging deeper"]),
            ReviewComment(severity: .nit, file: "lib/session.ts", lines: "L50–52", title: "Public key is re-imported on every request",
                          body: "`importSPKI` parses the PEM on each call.",
                          fixes: ["Keep the promise at module scope."],
                          code: [CodeLine(no: 51, mark: "+", text: "  return importSPKI(process.env.JWT_PUBLIC_KEY!, 'RS256');")],
                          highlight: [51], context: [], asks: [], foundBy: ["performance"])
        ], verdict: .hold, reason: "Revoked sessions keep working until the isolate recycles, which can be hours.")
        review.filesRead = 4
        review.contextFiles = 3
        review.seconds = 141
        review.headSha = "abc"
        review.agents = 13
        review.raised = 9
        review.dropped = [DroppedFinding(title: "`jose` is missing from package.json", file: "package.json", by: "correctness",
                                         why: "It was added in the same commit, on line 31.")]
        var record = ReviewRecord(review: review)
        record.threads["0"] = [ChatMessage(role: .user, text: "why does a warm isolate matter? I thought edge functions were stateless."),
                               ChatMessage(role: .assistant, text: "They're stateless between deploys, not between requests. Module-level variables like `sessionCache` live as long as the isolate does.")]
        // An approving review of #903, from before its latest commit.
        var older = Review(summary: "Rate limiting is applied per API key with a sliding window. Reads cleanly.", comments: [],
                           verdict: .approve, reason: "Small, well tested, and nothing in it needs to change.")
        older.filesRead = 3
        older.seconds = 28
        older.headSha = "0ld5ha1"
        let infra = prs.lists.review[3]
        var current = Review(summary: "A provider bump with no config changes.", comments: [], verdict: .approve, reason: "The plan output shows no resource changes.")
        current.headSha = infra.headSha
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID()).json")
        try JSONEncoder().encode([edge.id: record, prs.lists.review[1].id: ReviewRecord(review: older),
                                  infra.id: ReviewRecord(review: current)]).write(to: file)
        let reviews = ReviewStore(settings: settings, file: file)

        // A draft of the review for #1482, as claude would leave it.
        var draft = DraftStore.seed(record, diff: DraftDiffLines.parse("""
        diff --git a/middleware/auth.ts b/middleware/auth.ts
        --- a/middleware/auth.ts
        +++ b/middleware/auth.ts
        @@ -20,2 +20,10 @@
         import { jwtVerify } from 'jose';
        +
        +
        +const sessionCache = new Map<string, Session>();
        +
        +export async function middleware(req: NextRequest) {
        +  const token = req.cookies.get('session');
        +
        +  const cached = sessionCache.get(token);
         }
        """), mine: false)
        draft.body = "The move to `jose` looks good. One thing I'd like fixed before this goes in: the session cache."
        draft.comments[0].body = "This cache never evicts anything, and warm isolates can live for hours — so a revoked session keeps passing here. Could entries carry an expiry (60s?) and get checked on read?"
        draft.comments[1].body = "Small one: `importSPKI` parses the PEM on every request. Keeping the promise at module scope would avoid that."
        draft.chat = [ChatMessage(role: .user, text: "make the first one less blunt"),
                      ChatMessage(role: .assistant, text: "Softened the cache comment and turned it into a question.")]
        let draftFile = FileManager.default.temporaryDirectory.appendingPathComponent("render-drafts-\(UUID()).json")
        try JSONEncoder().encode([edge.id: draft]).write(to: draftFile)
        let drafts = DraftStore(settings: settings, file: draftFile)

        func render(_ name: String, height: CGFloat = 780) async throws {
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                try await render(name + (appearance == .darkAqua ? "" : "-light"), height: height, appearance: appearance)
            }
        }

        func render(_ name: String, height: CGFloat, appearance: NSAppearance.Name) async throws {
            let view = RootLayout(mode: .constant(.desk)) { DeskView() }
                .environmentObject(settings).environmentObject(app).environmentObject(prs)
                .environmentObject(reviews).environmentObject(drafts).environmentObject(updater)
                .frame(width: 1200, height: height)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 1200, height: height)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }

            try await Task.sleep(for: .milliseconds(800))
            hosting.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }

        app.route = .all; try await render("1-everything")
        app.route = .pr(prs.lists.review[2], from: .review); try await render("2-pr-idle")
        app.route = .pr(prs.lists.review[1], from: .review); try await render("2b-pr-outdated")
        app.route = .pr(edge, from: .all); try await render("3-pr-reviewed", height: 3400)
        app.route = .settings; try await render("4-settings", height: 2700)

        // A review mid-way: specialists done or waiting under a limit of 4.
        let pin = prs.lists.review[2]
        reviews.show(pin, .running(ReviewProgress(agents: [
            AgentRun(id: "first", stage: .firstPass, name: "first pass", state: .done(found: 2)),
            AgentRun(id: "correctness", stage: .specialists, name: "correctness", state: .done(found: 1)),
            AgentRun(id: "security", stage: .specialists, name: "security", state: .done(found: 0)),
            AgentRun(id: "style", stage: .specialists, name: "code style", state: .running),
            AgentRun(id: "tests", stage: .specialists, name: "tests", state: .failed),
            AgentRun(id: "performance", stage: .specialists, name: "performance", state: .running),
            AgentRun(id: "compat", stage: .specialists, name: "compatibility", state: .waiting),
            AgentRun(id: "focus0", stage: .focus, name: "dst handling in nextOccurrence", state: .running),
            AgentRun(id: "focus1", stage: .focus, name: "callers of toLocal", state: .waiting)
        ], background: true, contextFiles: 2)))
        app.route = .pr(pin, from: .review); try await render("8-pr-running", height: 900)
        reviews.show(pin, .failed("x"))
        // Half way through an approve-all.
        prs.show(approving: [prs.lists.review[2].id], queued: [prs.lists.review[3].id, prs.lists.review[1].id],
                 approved: [prs.lists.review[0]])
        app.route = .review; try await render("9-approve-all", height: 560)
        prs.show(approving: [], queued: [], approved: [])

        settings.agentName = "tanuki"
        app.route = .all; try await render("7-renamed")
        app.route = .pr(edge, from: .all); try await render("7b-renamed-pr", height: 1100)
        settings.agentName = ""
        if let body = try? String(contentsOfFile: ProcessInfo.processInfo.environment["PSYDUCK_DESK_RENDER_BODY"] ?? "") {
            let bump = pr("acme/api", 1501, "Bump the bundler-minor group with 1 update", "dependabot[bot]", .passing, .review, 3, 3, hours: 1, body: body)
            app.route = .pr(bump, from: .all); try await render("6-dependabot", height: 1400)
        }
        prs.lists = PRLists()
        app.route = .all; try await render("5-all-clear")
    }
}
