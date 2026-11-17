import AppKit
import SwiftUI
import XCTest
@testable import Psyduck

/// Typing in a draft's text boxes anywhere but the end used to land at the
/// end: the boxes were bound to a copy of the draft taken when the view drew.
@MainActor
final class InkEditorTests: XCTestCase {
    private let pr = DeskPullRequest(repo: "acme/api", number: 1, title: "t", url: "", body: "", author: "a", reviewers: [],
                                 checks: .passing, status: .review, additions: 0, deletions: 0, changedFiles: 0,
                                 updatedAt: Date(), headRef: "h", baseRef: "main", headSha: "abc")

    private struct Host: View {
        @ObservedObject var drafts: DraftStore
        let pr: DeskPullRequest
        let comment: String?
        var body: some View {
            VStack {
                // Reading the draft here redraws this view on every keystroke, as DraftEditor does.
                Text(drafts.draft(pr)?.body ?? "")
                InkEditor(text: comment.map { drafts.text(pr, comment: $0) } ?? drafts.text(pr))
            }
            .frame(width: 400)
        }
    }

    func testTypingInTheMiddleOfTheGeneralComment() throws {
        let drafts = try store()
        try type(into: Host(drafts: drafts, pr: pr, comment: nil))
        XCTAssertEqual(drafts.draft(pr)?.body, "abhello world")
    }

    func testTypingInTheMiddleOfALineComment() throws {
        let drafts = try store()
        try type(into: Host(drafts: drafts, pr: pr, comment: "0"))
        XCTAssertEqual(drafts.draft(pr)?.comments.first?.body, "abhello world")
    }

    private func store() throws -> DraftStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID()).json")
        let comment = DraftComment(id: "0", severity: .nit, title: "t", path: "a", lines: "L1", code: [], highlight: [],
                                   line: 1, startLine: nil, side: "RIGHT", body: "hello world")
        try JSONEncoder().encode([pr.id: ReviewDraft(body: "hello world", event: .comment, comments: [comment], sha: "abc")]).write(to: file)
        return DraftStore(settings: DeskSettings(defaults: UserDefaults(suiteName: "e-\(UUID())")!), file: file)
    }

    /// Puts the cursor at the start and types "ab".
    private func type<V: View>(into view: V) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.layoutIfNeeded()
        let editor = try XCTUnwrap(textView(in: window.contentView!))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        for character in ["a", "b"] {
            editor.insertText(character, replacementRange: editor.selectedRange())
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(editor.string, "abhello world")
        XCTAssertEqual(editor.selectedRange().location, 2)
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for sub in view.subviews { if let found = textView(in: sub) { return found } }
        return nil
    }
}
