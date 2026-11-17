import XCTest
@testable import Psyduck

/// Runs a real review through claude against a real pull request. Slow and
/// billed, so it only runs when asked:
///
///   TEST_RUNNER_PSYDUCK_DESK_LIVE_REVIEW=owner/repo#4 xcodebuild test …
@MainActor
final class LiveReviewTests: XCTestCase {
    func testAReviewComesBackFromClaude() async throws {
        let target = ProcessInfo.processInfo.environment["PSYDUCK_DESK_LIVE_REVIEW"] ?? ""
        try XCTSkipIf(target.isEmpty, "set PSYDUCK_DESK_LIVE_REVIEW=owner/repo#number to run")
        let parts = target.split(separator: "#")
        let repo = String(parts[0])
        let number = String(parts[1])

        let gh = try Shell.resolve("gh", configured: "")
        let view = try await Shell.run(gh, ["pr", "view", number, "--repo", repo, "--json",
            "number,title,url,body,author,additions,deletions,changedFiles,headRefName,baseRefName,headRefOid"])
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(view.stdout.utf8)) as? [String: Any])
        let pr = DeskPullRequest(
            repo: repo, number: info["number"] as! Int, title: info["title"] as! String,
            url: info["url"] as! String, body: info["body"] as! String,
            author: (info["author"] as! [String: Any])["login"] as! String, reviewers: [],
            checks: .none, status: .review,
            additions: info["additions"] as! Int, deletions: info["deletions"] as! Int,
            changedFiles: info["changedFiles"] as! Int, updatedAt: Date(),
            headRef: info["headRefName"] as! String, baseRef: info["baseRefName"] as! String,
            headSha: info["headRefOid"] as! String)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID()).json")
        let settings = DeskSettings(defaults: UserDefaults(suiteName: "live-\(UUID())")!)
        let store = ReviewStore(settings: settings, file: file)
        var agents: Set<String> = []
        store.start(pr)

        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            switch store.run(pr) {
            case .running(let progress)?:
                for agent in progress.agents { agents.insert("\(agent.stage.rawValue)/\(agent.name)") }
                try await Task.sleep(for: .milliseconds(200))
                continue
            case .failed(let message)?:
                return XCTFail("review failed: \(message)")
            case nil:
                guard let record = store.record(pr) else { return XCTFail("review went back to idle") }
                print("LIVE agents seen: \(agents.sorted())")
                for d in record.review.dropped { print("LIVE dropped: \(d.by) · \(d.file) · \(d.title) — \(d.why)") }
                print("LIVE meta: \(record.review.meta)")
                print("LIVE summary: \(record.review.summary)")
                print("LIVE verdict: \(record.review.verdict?.rawValue ?? "none") — \(record.review.reason)")
                for c in record.review.comments {
                    print("LIVE comment: [\(c.severity.rawValue)] \(c.file) \(c.lines) — \(c.title) · by \(c.foundBy ?? []) · \(c.code.count) lines · \(c.context.count) context · asks \(c.asks)")
                }
                XCTAssertFalse(record.review.summary.isEmpty)
                XCTAssertNotNil(record.review.verdict)
                XCTAssertGreaterThan(record.review.agents, 1)
                XCTAssertTrue(record.review.comments.allSatisfy { $0.foundBy?.isEmpty == false })
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the review should be saved")

                // Then the draft you'd post — drafted, never posted.
                let drafts = DraftStore(settings: settings, file: FileManager.default.temporaryDirectory.appendingPathComponent("live-drafts-\(UUID()).json"))
                drafts.start(pr, from: record, mine: false)
                while drafts.busy[pr.id] != nil || drafts.draft(pr) == nil {
                    if let error = drafts.errors[pr.id], drafts.busy[pr.id] == nil { return XCTFail("draft failed: \(error)") }
                    try await Task.sleep(for: .milliseconds(200))
                }
                let draft = try XCTUnwrap(drafts.draft(pr))
                print("LIVE draft error: \(drafts.errors[pr.id] ?? "none")")
                print("LIVE draft event: \(draft.event.rawValue)")
                print("LIVE draft body: \(draft.body)")
                for c in draft.comments {
                    print("LIVE draft comment: \(c.path) line \(c.line.map(String.init) ?? "off the diff") start \(c.startLine.map(String.init) ?? "-") \(c.side) include \(c.include): \(c.body)")
                }
                print("LIVE payload: \(String(data: try JSONEncoder().encode(draft.payload), encoding: .utf8)!)")
                XCTAssertNil(drafts.errors[pr.id])
                return
            }
        }
        XCTFail("review didn't finish in ten minutes")
    }
}
