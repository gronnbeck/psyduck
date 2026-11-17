import XCTest
@testable import Psyduck

final class TsukueImportTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tsukue-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "tsukue-import-\(UUID())")!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func importNow(bundleID: String = "lol.np.psyduck", settings: [String: [String: Any]] = [:]) {
        TsukueImport.runOnce(defaults: defaults, bundleID: bundleID, appSupport: root,
                             destination: root.appendingPathComponent("\(bundleID)/desk"),
                             settings: { settings[$0] })
    }

    func testCopiesDataAndSettingsOnceAndLeavesTsukueAlone() throws {
        try write("reviews", "lol.np.tsukue/reviews.json")
        try write("history", "lol.np.tsukue/review-history.jsonl")
        importNow(settings: ["lol.np.tsukue": ["agentName": "tanuki", "maxAgents": 3, "unrelated": 1]])

        XCTAssertEqual(read("lol.np.psyduck/desk/reviews.json"), "reviews")
        XCTAssertEqual(read("lol.np.psyduck/desk/review-history.jsonl"), "history")
        XCTAssertNil(read("lol.np.psyduck/desk/drafts.json"))
        XCTAssertEqual(read("lol.np.tsukue/reviews.json"), "reviews")
        XCTAssertEqual(defaults.string(forKey: "desk.agentName"), "tanuki")
        XCTAssertEqual(defaults.integer(forKey: "desk.maxAgents"), 3)
        XCTAssertNil(defaults.object(forKey: "desk.unrelated"))

        // A second run does nothing, even if tsukue has changed since.
        try write("newer", "lol.np.tsukue/reviews.json")
        importNow(settings: ["lol.np.tsukue": ["agentName": "kitsune"]])
        XCTAssertEqual(read("lol.np.psyduck/desk/reviews.json"), "reviews")
        XCTAssertEqual(defaults.string(forKey: "desk.agentName"), "tanuki")
    }

    func testNeverOverwritesWhatDeskAlreadyHas() throws {
        try write("old", "lol.np.tsukue/reviews.json")
        try write("mine", "lol.np.psyduck/desk/drafts.json")
        defaults.set("mine", forKey: "desk.agentName")
        importNow(settings: ["lol.np.tsukue": ["agentName": "tanuki", "maxAgents": 3]])

        XCTAssertNil(read("lol.np.psyduck/desk/reviews.json"))
        XCTAssertEqual(read("lol.np.psyduck/desk/drafts.json"), "mine")
        XCTAssertEqual(defaults.string(forKey: "desk.agentName"), "mine")
        XCTAssertNil(defaults.object(forKey: "desk.maxAgents"))
    }

    func testAnEdgeBuildPrefersEdgeTsukue() throws {
        try write("release", "lol.np.tsukue/reviews.json")
        try write("edge", "lol.np.tsukue.edge/reviews.json")
        importNow(bundleID: "lol.np.psyduck.edge")
        XCTAssertEqual(read("lol.np.psyduck.edge/desk/reviews.json"), "edge")
    }

    func testNothingToImportIsFine() {
        importNow()
        XCTAssertNil(read("lol.np.psyduck/desk/reviews.json"))
        XCTAssertTrue(defaults.bool(forKey: TsukueImport.doneKey))
    }
}
