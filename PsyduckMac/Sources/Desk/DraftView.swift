import SwiftUI

/// "your review": the one you post on GitHub, drafted from claude's review,
/// edited by hand or by asking, and posted only on the button.
struct DraftSection: View {
    @EnvironmentObject private var drafts: DraftStore
    @EnvironmentObject private var reviews: ReviewStore
    @EnvironmentObject private var prs: PRStore
    @EnvironmentObject private var settings: DeskSettings
    let pr: DeskPullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("your review").font(.display(20)).foregroundStyle(Ink.ink)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "paperplane").font(.system(size: 11, weight: .medium))
                    Text("posted to github only when you press post review.")
                }
                .font(.sans(13))
                .foregroundStyle(Ink.inkMuted)
            }
            if let error = drafts.errors[pr.id] {
                Text(error).font(.sans(13)).foregroundStyle(Ink.danger).textSelection(.enabled)
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if drafts.busy[pr.id] == "drafting" {
            Card { Dots(text: "\(settings.agent) is drafting your review").font(.mono(13)).foregroundStyle(Ink.inkMuted) }
        } else if let draft = drafts.draft(pr) {
            if draft.postedAt != nil {
                Posted(pr: pr, draft: draft)
            } else {
                DraftEditor(pr: pr, draft: draft)
            }
        } else if let record = reviews.record(pr) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("turn \(settings.agent)'s review into one you post. \(settings.agent) drafts the comments for \(pr.author), you change them here or by asking, and nothing goes to github until you press post review.")
                        .font(.sans(14)).lineSpacing(6).foregroundStyle(Ink.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if reviews.isOutdated(pr) {
                        Text("the review is of an older commit. review again first, so the comments land on the right lines.")
                            .font(.sans(13)).foregroundStyle(Ink.danger)
                    } else {
                        Button("draft review with \(settings.agent) →") {
                            drafts.start(pr, from: record, mine: prs.isMine(pr))
                        }
                        .buttonStyle(HardButtonStyle())
                        .disabled(reviews.isRunning(pr))
                    }
                }
            }
        }
    }
}

private struct DraftEditor: View {
    @EnvironmentObject private var drafts: DraftStore
    @EnvironmentObject private var prs: PRStore
    @EnvironmentObject private var settings: DeskSettings
    let pr: DeskPullRequest
    let draft: ReviewDraft
    @State private var confirming = false

    private var busy: String? { drafts.busy[pr.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("submit as").microLabel().padding(.trailing, 4)
                    ForEach(events, id: \.self) { event in
                        EventChip(event: event, on: draft.event == event) {
                            drafts.update(pr) { $0.event = event }
                        }
                    }
                }
                Text("general comment").microLabel()
                InkEditor(text: drafts.text(pr), placeholder: "what you think of the change overall", minHeight: 60)
            }
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkBox(12, fill: Ink.bg200)

            if !draft.comments.isEmpty {
                HStack(spacing: 8) {
                    Text("line comments").microLabel()
                    Text("\(draft.included.count) of \(draft.comments.count) going out").font(.mono(12)).foregroundStyle(Ink.inkMuted)
                }
                .padding(.top, 4)
                ForEach(Array(draft.comments.enumerated()), id: \.element.id) { index, comment in
                    DraftCommentCard(comment: comment,
                                     include: drafts.include(pr, comment: comment.id),
                                     text: drafts.text(pr, comment: comment.id))
                }
            }

            DraftChat(pr: pr, draft: draft)

            HStack(spacing: 12) {
                Button("discard draft") { drafts.discard(pr) }
                    .buttonStyle(GhostButtonStyle(size: 13, color: Ink.inkMuted))
                Spacer(minLength: 0)
                if draft.missingBody {
                    Text("github needs a general comment for this kind of review.").font(.sans(13)).foregroundStyle(Ink.inkMuted)
                }
                if busy == "posting" {
                    Dots(text: "posting").font(.mono(13, .medium)).foregroundStyle(Ink.inkMuted)
                } else {
                    Button("post review →") { confirming = true }
                        .buttonStyle(HardButtonStyle())
                        .disabled(busy != nil || draft.missingBody)
                        .confirmationDialog("post your review of \(pr.ref)?", isPresented: $confirming) {
                            Button("post review") { Task { await drafts.post(pr); await prs.refresh() } }
                            Button("cancel", role: .cancel) {}
                        } message: {
                            Text(Self.summary(draft, pr: pr))
                        }
                }
            }
        }
        .disabled(busy == "editing")
    }

    private var events: [ReviewDraft.Event] {
        prs.isMine(pr) ? [.comment] : ReviewDraft.Event.allCases
    }

    /// What the confirm dialog says is about to happen.
    static func summary(_ draft: ReviewDraft, pr: DeskPullRequest) -> String {
        let pinned = draft.included.filter(\.onDiff).count
        let loose = draft.included.count - pinned
        var lines = ["submitted as \(draft.event.rawValue), with \(pinned) line comment\(pinned == 1 ? "" : "s")."]
        if loose > 0 { lines.append("\(loose) comment\(loose == 1 ? " isn't" : "s aren't") on the diff, so \(loose == 1 ? "it goes" : "they go") in the general comment.") }
        if !pr.headSha.isEmpty, draft.sha != pr.headSha {
            lines.append("the pull request has new commits since this was drafted. the comments are posted on the commit that was reviewed.")
        }
        lines.append("this posts to github as you.")
        return lines.joined(separator: "\n\n")
    }
}

private struct EventChip: View {
    let event: ReviewDraft.Event
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(event.rawValue)
                .font(.sans(13, .semibold))
                .foregroundStyle(on ? text : Ink.inkMuted)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(on ? fill : Ink.bg200))
                .overlay { if !on { Capsule().strokeBorder(Ink.lineStrong, lineWidth: 1) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: on)
    }

    private var fill: Color {
        switch event {
        case .comment: return Ink.bg300
        case .approve: return Ink.brand
        case .requestChanges: return Ink.danger
        }
    }

    private var text: Color {
        switch event {
        case .comment: return Ink.ink
        case .approve: return Ink.onBrand
        case .requestChanges: return Ink.onDanger
        }
    }
}

private struct DraftCommentCard: View {
    let comment: DraftComment
    @Binding var include: Bool
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { include.toggle() } label: {
                    CheckMark(on: include, size: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(include ? "leave this one out" : "post this one")
                Badge(text: comment.severity.rawValue, dot: comment.severity.dot)
                Text(comment.path).font(.mono(13, .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(lineLabel).font(.mono(12)).foregroundStyle(Ink.inkMuted)
                Spacer(minLength: 0)
                if !comment.onDiff {
                    Text("not on the diff · goes in the general comment").font(.sans(12, .semibold)).foregroundStyle(Ink.inkMuted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if include {
                Rectangle().fill(Ink.line).frame(height: Ink.border)
                if !comment.code.isEmpty {
                    CodeBlock(lines: comment.code, highlight: pinned)
                        .background(Ink.bg000)
                    Rectangle().fill(Ink.line).frame(height: Ink.border)
                }
                InkEditor(text: $text, placeholder: "what you want to say on this line")
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .inkBox(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.bg200))
        .opacity(include ? 1 : 0.6)
        .animation(.easeOut(duration: 0.12), value: include)
    }

    /// The lines the comment will sit on, as GitHub will show them.
    private var pinned: [Int] {
        guard let line = comment.line else { return comment.highlight }
        return Array((comment.startLine ?? line)...line)
    }

    private var lineLabel: String {
        guard let line = comment.line else { return comment.lines }
        if let start = comment.startLine { return "on L\(start)–\(line)" }
        return "on L\(line)"
    }
}

private struct DraftChat: View {
    @EnvironmentObject private var drafts: DraftStore
    @EnvironmentObject private var prs: PRStore
    @EnvironmentObject private var settings: DeskSettings
    let pr: DeskPullRequest
    let draft: ReviewDraft

    var body: some View {
        let editing = drafts.busy[pr.id] == "editing"
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("change it by asking").microLabel()
                ForEach(Array(draft.chat.enumerated()), id: \.offset) { _, message in
                    switch message.role {
                    case .user:
                        HStack {
                            Spacer(minLength: 120)
                            Text(message.text)
                                .font(.sans(14)).foregroundStyle(Ink.ink)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.bg300))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.line, lineWidth: Ink.border))
                        }
                    case .assistant:
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(settings.agent).font(.mono(11)).foregroundStyle(Ink.inkMuted)
                            SegmentedText(text: message.text, size: 14)
                        }
                    case .error:
                        Text(message.text).font(.sans(13)).foregroundStyle(Ink.danger)
                    }
                }
                if editing {
                    Dots(text: "\(settings.agent) is editing the draft").font(.mono(12)).foregroundStyle(Ink.inkMuted)
                }
                if draft.chat.isEmpty && !editing {
                    HStack(spacing: 8) {
                        ForEach(["make it friendlier", "drop the nits", "shorter"], id: \.self) { ask in
                            Button(ask) { drafts.ask(pr, ask, mine: prs.isMine(pr)) }
                                .buttonStyle(ChipButtonStyle())
                        }
                    }
                }
                HStack(spacing: 8) {
                    InkField(placeholder: "ask \(settings.agent) to change the draft", text: text) {
                        drafts.ask(pr, text.wrappedValue, mine: prs.isMine(pr))
                    }
                    Button("ask") { drafts.ask(pr, text.wrappedValue, mine: prs.isMine(pr)) }
                        .buttonStyle(HardButtonStyle())
                        .disabled(editing)
                }
            }
        }
    }

    private var text: Binding<String> {
        Binding(get: { drafts.input[pr.id] ?? "" }, set: { drafts.input[pr.id] = $0 })
    }
}

private struct Posted: View {
    @EnvironmentObject private var drafts: DraftStore
    let pr: DeskPullRequest
    let draft: ReviewDraft

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Ink.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("posted to github").font(.sans(14, .semibold)).foregroundStyle(Ink.ink)
                Text("\(draft.event.rawValue) · \(draft.included.count) comment\(draft.included.count == 1 ? "" : "s") · \(draft.postedAt.map { Ago.long($0) } ?? "")")
                    .font(.mono(12)).foregroundStyle(Ink.inkMuted)
            }
            Spacer(minLength: 0)
            if let url = draft.postedURL.flatMap(URL.init(string:)) {
                Button("view on github ↗") { NSWorkspace.shared.open(url) }
                    .buttonStyle(GhostButtonStyle(size: 13))
            }
            Button("start another") { drafts.discard(pr) }
                .buttonStyle(GhostButtonStyle(size: 13))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .inkBox(12, fill: Ink.bg200)
        .overlay(alignment: .leading) { Rectangle().fill(Ink.success).frame(width: 3).padding(.vertical, 1) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Bindings for the draft's text boxes. They read the draft from the store
/// every time, never a copy taken when the view drew: mid-keystroke that copy
/// is one edit behind, and handing it back to the editor moves the cursor to
/// the end — you could only type at the end.
extension DraftStore {
    func text(_ pr: DeskPullRequest) -> Binding<String> {
        Binding(get: { self.draft(pr)?.body ?? "" },
                set: { text in self.update(pr) { $0.body = text } })
    }

    func text(_ pr: DeskPullRequest, comment id: String) -> Binding<String> {
        Binding(get: { self.draft(pr)?.comments.first { $0.id == id }?.body ?? "" },
                set: { text in self.update(pr) { draft in
                    if let i = draft.comments.firstIndex(where: { $0.id == id }) { draft.comments[i].body = text }
                } })
    }

    func include(_ pr: DeskPullRequest, comment id: String) -> Binding<Bool> {
        Binding(get: { self.draft(pr)?.comments.first { $0.id == id }?.include ?? false },
                set: { on in self.update(pr) { draft in
                    if let i = draft.comments.firstIndex(where: { $0.id == id }) { draft.comments[i].include = on }
                } })
    }
}
