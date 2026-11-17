import SwiftUI

struct PRDetailView: View {
    @EnvironmentObject private var settings: DeskSettings
    @EnvironmentObject private var reviews: ReviewStore
    @EnvironmentObject private var prs: PRStore
    let pr: DeskPullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            if let error = prs.approveErrors[pr.id] {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("not approved").font(.sans(14, .semibold)).foregroundStyle(Ink.danger)
                        Text(error).font(.mono(12)).foregroundStyle(Ink.inkMuted).textSelection(.enabled)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "description")
                Card { Description(text: pr.body) }
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(settings.agent) review").font(.display(20)).foregroundStyle(Ink.ink)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Image(systemName: "lock").font(.system(size: 11, weight: .medium))
                        Text("stays in desk. nothing is posted to github.")
                    }
                    .font(.sans(13))
                    .foregroundStyle(Ink.inkMuted)
                }
                ReviewBody(pr: pr)
            }

            if reviews.record(pr) != nil {
                DraftSection(pr: pr)
            }
        }
        .frame(maxWidth: 880, alignment: .leading)
    }
}

private struct Description: View {
    let text: String

    var body: some View {
        let blocks = DeskProse.blocks(text)
        if blocks.isEmpty {
            Text("no description.").font(.sans(14)).foregroundStyle(Ink.inkMuted)
        } else {
            ProseList(blocks: blocks)
        }
    }
}

private struct ProseList: View {
    let blocks: [ProseBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                Group {
                    switch block.kind {
                    case .heading:
                        SegmentedText(text: block.text, size: block.level <= 2 ? 17 : block.level == 3 ? 15 : 14, weight: .semibold)
                    case .item:
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            ItemMarker(marker: block.marker)
                            SegmentedText(text: block.text)
                        }
                        .padding(.leading, CGFloat(block.level) * 22)
                    case .paragraph:
                        SegmentedText(text: block.text)
                    case .code:
                        ProseCode(text: block.text)
                    case .table:
                        ProseTable(rows: block.rows)
                    case .quote:
                        // Type-erased: a quote can hold anything a description can.
                        AnyView(ProseList(blocks: block.children))
                            .padding(.leading, 16)
                            .overlay(alignment: .leading) { Rectangle().fill(Ink.lineStrong).frame(width: 2) }
                            .opacity(0.85)
                    case .details:
                        DetailsSection(block: block)
                    }
                }
                .padding(.top, index == 0 ? 0 : gap(before: block, after: blocks[index - 1]))
            }
        }
    }

    /// List items sit close together, a heading gets air above it, everything
    /// else is a paragraph apart.
    private func gap(before block: ProseBlock, after previous: ProseBlock) -> CGFloat {
        switch (previous.kind, block.kind) {
        case (.item, .item): return 6
        case (_, .heading): return 22
        case (.heading, _): return 8
        case (_, .item), (.item, _): return 10
        default: return 14
        }
    }
}

/// What a list item starts with: a dash, its number, or a task's checkbox.
private struct ItemMarker: View {
    let marker: String?

    var body: some View {
        switch marker {
        case "[ ]": Image(systemName: "square").font(.system(size: 12)).foregroundStyle(Ink.inkMuted)
        case "[x]": Image(systemName: "checkmark.square.fill").font(.system(size: 12)).foregroundStyle(Ink.brandText)
        case let number?: Text(number).font(.mono(13)).foregroundStyle(Ink.inkMuted)
        case nil: Text("–").font(.sans(14)).foregroundStyle(Ink.inkMuted)
        }
    }
}

/// A fenced code block: its lines as written, scrolling sideways if long.
private struct ProseCode: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text.isEmpty ? " " : text)
                .font(.mono(12.5))
                .lineSpacing(5)
                .foregroundStyle(Ink.ink)
                .textSelection(.enabled)
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkBox(8, fill: Ink.bg100)
    }
}

/// A table: a quieter header, a hairline between rows.
private struct ProseTable: View {
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(Ink.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        SegmentedText(text: cell, size: 13, weight: index == 0 ? .semibold : .regular,
                                      color: index == 0 ? Ink.inkMuted : Ink.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .inkBox(8)
    }
}

/// A `<details>` section: closed until asked, as on GitHub.
private struct DetailsSection: View {
    let block: ProseBlock
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    Text(block.text.lowercased()).font(.sans(14, .semibold))
                }
                .foregroundStyle(Ink.inkMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                // Type-erased: the list can contain more details sections.
                AnyView(ProseList(blocks: block.children))
                    .padding(.leading, 20)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Ink.line).frame(width: 1).padding(.leading, 5)
                    }
            }
        }
        .animation(.easeOut(duration: 0.12), value: open)
    }
}

// MARK: Review states

/// The header button: start, running, run again.
struct ReviewButton: View {
    @EnvironmentObject private var settings: DeskSettings
    @EnvironmentObject private var reviews: ReviewStore
    let pr: DeskPullRequest

    var body: some View {
        if reviews.isRunning(pr) {
            HStack(spacing: 8) {
                PulseDot(color: Ink.info, pulsing: true)
                Dots(text: "reviewing").frame(minWidth: 84, alignment: .leading)
            }
            .font(.mono(12, .medium))
            .foregroundStyle(Ink.inkMuted)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .inkBox(8, fill: Ink.bg300)
        } else if reviews.isOutdated(pr) {
            Button("review again →") { reviews.start(pr) }
                .buttonStyle(HardButtonStyle())
        } else if reviews.record(pr) != nil || reviews.run(pr) != nil {
            Button("run again") { reviews.start(pr) }
                .buttonStyle(HardButtonStyle(kind: .outlined))
        } else {
            Button("review with \(settings.agent) →") { reviews.start(pr) }
                .buttonStyle(HardButtonStyle())
        }
    }
}

/// Approves on GitHub, as you — after saying what claude thinks of it.
struct ApproveButton: View {
    @EnvironmentObject private var settings: DeskSettings
    @EnvironmentObject private var prs: PRStore
    @EnvironmentObject private var reviews: ReviewStore
    let pr: DeskPullRequest
    @State private var confirming = false

    var body: some View {
        if prs.isMine(pr) {
            EmptyView()
        } else if prs.approving.contains(pr.id) {
            Dots(text: "approving")
                .font(.mono(12, .medium))
                .foregroundStyle(Ink.inkMuted)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .inkBox(8, fill: Ink.bg300)
        } else if prs.isApproved(pr) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                Text("approved")
            }
            .font(.sans(13, .semibold))
            .foregroundStyle(Ink.success)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .inkBox(8, fill: Ink.bg200)
        } else {
            // One lime button per view: approve takes it only when a current
            // review would approve; otherwise reviewing is the thing to do.
            let primary = reviews.record(pr)?.review.verdict == .approve && !reviews.isOutdated(pr)
            Button(prs.approvedSha(pr) == nil ? "approve" : "approve again") { confirming = true }
                .buttonStyle(HardButtonStyle(kind: primary ? .filled : .outlined))
                .confirmationDialog("approve \(pr.ref) on github?", isPresented: $confirming) {
                    Button("approve") { Task { await prs.approve(pr) } }
                    Button("cancel", role: .cancel) {}
                } message: {
                    Text(Self.warning(record: reviews.record(pr), outdated: reviews.isOutdated(pr), agent: settings.agent))
                }
        }
    }

    /// What claude thinks, so the dialog never approves blind.
    static func warning(record: ReviewRecord?, outdated: Bool, agent: String = "claude") -> String {
        let posts = "this posts an approval to github as you."
        guard let review = record?.review else { return "\(agent) hasn't reviewed this yet. " + posts }
        var lines: [String] = []
        if outdated { lines.append("\(agent)'s review is of an older commit.") }
        switch review.verdict {
        case .approve?: lines.append("\(agent) would approve: " + review.reason)
        case .hold?: lines.append("\(agent) says hold off: " + review.reason)
        case nil: break
        }
        let blocking = review.comments.filter { $0.severity == .blocking }.count
        if blocking > 0 { lines.append("\(blocking) blocking comment\(blocking == 1 ? "" : "s").") }
        lines.append(posts)
        return lines.joined(separator: "\n\n")
    }
}

private struct ReviewBody: View {
    @EnvironmentObject private var settings: DeskSettings
    @EnvironmentObject private var reviews: ReviewStore
    let pr: DeskPullRequest

    var body: some View {
        let record = reviews.record(pr)
        let outdated = reviews.isOutdated(pr)
        VStack(alignment: .leading, spacing: 24) {
            switch reviews.run(pr) {
            case .running(let progress)?:
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        if outdated {
                            Text("new commits · reviewing again").microLabel().padding(.bottom, 4)
                        } else if progress.background {
                            Text("reviewing in the background").microLabel().padding(.bottom, 4)
                        }
                        ForEach(ReviewStage.allCases, id: \.self) { stage in
                            StageLine(stage: stage, agents: progress.agents(stage), started: !progress.agents.isEmpty)
                        }
                        if progress.contextFiles > 0 {
                            Text("pulled in \(progress.contextFiles) file\(progress.contextFiles == 1 ? "" : "s") from outside the diff so far")
                                .font(.mono(12)).foregroundStyle(Ink.inkMuted).padding(.top, 4)
                        }
                    }
                }
            case .failed(let message)?:
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("the review didn't finish").font(.sans(14, .semibold)).foregroundStyle(Ink.danger)
                        Text(message).font(.mono(12)).foregroundStyle(Ink.inkMuted).textSelection(.enabled)
                    }
                }
            case nil:
                if record == nil {
                    Card {
                        Text("not reviewed yet. \(settings.agent) reads the diff, pulls in whatever code it needs to understand it, and leaves its comments here.")
                            .font(.sans(14)).lineSpacing(6).foregroundStyle(Ink.inkMuted)
                    }
                }
            }
            if let record {
                ReviewDone(pr: pr, record: record, outdated: outdated, rerunning: reviews.isRunning(pr))
            }
        }
    }

}

/// A stage of a running review, and its agents underneath.
private struct StageLine: View {
    let stage: ReviewStage
    let agents: [AgentRun]
    let started: Bool

    private var finished: Bool {
        !agents.isEmpty && agents.allSatisfy {
            if case .done = $0.state { return true }
            return $0.state == .failed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                if finished {
                    Text("✓").foregroundStyle(Ink.success).frame(width: 12)
                    Text(stage.label + summary).foregroundStyle(Ink.inkMuted)
                } else if !agents.isEmpty {
                    Text("›").foregroundStyle(Ink.ink).frame(width: 12)
                    Dots(text: stage.label).foregroundStyle(Ink.ink)
                } else {
                    Text("·").foregroundStyle(Ink.inkFaint).frame(width: 12)
                    Text(stage.label).foregroundStyle(Ink.inkFaint)
                }
            }
            .font(.mono(13))
            if !finished {
                ForEach(agents) { agent in
                    AgentLine(agent: agent).padding(.leading, 24)
                }
            }
        }
    }

    private var summary: String {
        let found = agents.reduce(0) { n, agent in
            if case .done(let k) = agent.state { return n + k }
            return n
        }
        let failed = agents.filter { $0.state == .failed }.count
        var parts = [stage == .verify ? "\(found) held up" : "\(found) found"]
        if agents.count > 1 { parts.insert("\(agents.count) agents", at: 0) }
        if failed > 0 { parts.append("\(failed) didn't finish") }
        return " · " + parts.joined(separator: " · ")
    }
}

private struct AgentLine: View {
    let agent: AgentRun

    var body: some View {
        HStack(spacing: 10) {
            switch agent.state {
            case .waiting:
                Text("·").foregroundStyle(Ink.inkFaint).frame(width: 12)
                Text(agent.name).foregroundStyle(Ink.inkMuted)
                Text("waiting for a slot").foregroundStyle(Ink.inkFaint)
            case .running:
                Text("›").foregroundStyle(Ink.ink).frame(width: 12)
                Dots(text: agent.name).foregroundStyle(Ink.ink)
            case .done(let found):
                Text("✓").foregroundStyle(Ink.success).frame(width: 12)
                Text(agent.name).foregroundStyle(Ink.inkMuted)
                Text(agent.stage == .verify ? "\(found) held up" : "\(found) found").foregroundStyle(Ink.inkMuted)
            case .failed:
                Text("✗").foregroundStyle(Ink.danger).frame(width: 12)
                Text(agent.name).foregroundStyle(Ink.inkMuted)
                Text("didn't finish").foregroundStyle(Ink.danger)
            }
        }
        .font(.mono(12))
        .lineLimit(1)
    }
}

extension ReviewComment.Severity {
    var dot: Color {
        switch self {
        case .blocking: return Ink.danger
        case .shouldFix: return Ink.warning
        case .nit: return Ink.inkFaint
        }
    }
}

extension Review.Verdict {
    var label: String { self == .approve ? "would approve" : "hold off" }
    var dot: Color { self == .approve ? Ink.success : Ink.warning }
}

private struct ReviewDone: View {
    @EnvironmentObject private var settings: DeskSettings
    @EnvironmentObject private var reviews: ReviewStore
    let pr: DeskPullRequest
    let record: ReviewRecord
    let outdated: Bool
    let rerunning: Bool

    var body: some View {
        let review = record.review
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("\(settings.agent)'s take").microLabel().padding(.trailing, 4)
                    if review.comments.isEmpty {
                        Badge(text: "no comments", dot: Ink.success)
                    }
                    ForEach(ReviewComment.Severity.allCases, id: \.self) { severity in
                        let n = review.comments.filter { $0.severity == severity }.count
                        if n > 0 {
                            Badge(text: "\(n) \(severity.rawValue)", dot: severity.dot)
                        }
                    }
                    Spacer(minLength: 0)
                    if !review.comments.isEmpty {
                        CopyButton(text: FixPrompt.review(record, pr: pr), label: "copy all")
                    }
                }
                SegmentedText(text: review.summary)
                if let verdict = review.verdict {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Badge(text: verdict.label, dot: verdict.dot)
                        SegmentedText(text: review.reason, size: 14)
                    }
                }
                Text(settings.agent + " · " + review.meta + (review.headSha.isEmpty ? "" : " · at \(review.headSha.prefix(7))"))
                    .font(.mono(12)).foregroundStyle(Ink.inkMuted)
                if !review.dropped.isEmpty {
                    DroppedList(dropped: review.dropped)
                }
            }
            .padding(EdgeInsets(top: outdated ? 64 : 20, leading: 24, bottom: 20, trailing: 24))
            .opacity(outdated ? 0.6 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkBox(12, fill: Ink.bg200)
            .overlay(alignment: .top) {
                if outdated { stale }
            }

            ForEach(Array(review.comments.enumerated()), id: \.offset) { index, comment in
                CommentCard(pr: pr, comment: comment, index: index, total: review.comments.count,
                            thread: record.thread(index))
            }
        }
    }
}

/// Findings the checkers threw out, folded away but there to see.
private struct DroppedList: View {
    let dropped: [DroppedFinding]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold))
                    Text("\(dropped.count) finding\(dropped.count == 1 ? "" : "s") didn't hold up")
                }
                .font(.mono(12)).foregroundStyle(Ink.inkMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(Array(dropped.enumerated()), id: \.offset) { _, d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.title).font(.sans(13, .semibold)).foregroundStyle(Ink.inkMuted)
                        Text("\(d.by) · \(d.file)").font(.mono(11)).foregroundStyle(Ink.inkMuted)
                        Text(d.why).font(.sans(13)).foregroundStyle(Ink.inkMuted).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .padding(.top, 4)
    }
}

extension ReviewDone {
    /// Pinned to the top of a review the PR has moved on from.
    private var stale: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .bold))
            Text("out of date · reviewed \(record.review.headSha.prefix(7)), the pull request is now at \(pr.headSha.prefix(7))")
                .font(.sans(13, .semibold))
            Spacer(minLength: 0)
            if !rerunning {
                Button("review again →") { reviews.start(pr) }
                    .buttonStyle(GhostButtonStyle(size: 13, color: Ink.onBrand))
            }
        }
        .foregroundStyle(Ink.onBrand)
        .padding(.leading, 20)
        .padding(.trailing, rerunning ? 20 : 8)
        .frame(height: 40)
        .background(Ink.sun)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: Ink.border) }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous).strokeBorder(Ink.line, lineWidth: Ink.border))
    }
}

// MARK: Comment

/// Copies a comment as a prompt to hand to claude for the fix.
private struct CopyButton: View {
    let text: String
    var label = "copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                Text(copied ? "copied" : label)
            }
        }
        .buttonStyle(GhostButtonStyle(size: 12, color: copied ? Ink.success : Ink.inkMuted))
        .help("copy as a prompt for claude to fix")
    }
}

private struct CommentCard: View {
    @EnvironmentObject private var settings: DeskSettings
    @EnvironmentObject private var reviews: ReviewStore
    let pr: DeskPullRequest
    let comment: ReviewComment
    let index: Int
    let total: Int
    let thread: [ChatMessage]

    private var key: String { ReviewStore.key(pr, index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Badge(text: comment.severity.rawValue, dot: comment.severity.dot)
                Text(comment.file).font(.mono(13, .medium)).foregroundStyle(Ink.ink).lineLimit(1)
                Text(comment.lines).font(.mono(12)).foregroundStyle(Ink.inkMuted)
                Spacer(minLength: 0)
                CopyButton(text: FixPrompt.comment(comment, thread: thread, pr: pr))
                Text("\(index + 1) / \(total)").font(.mono(12)).foregroundStyle(Ink.inkMuted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            rule(Ink.line, 1)
            if !comment.code.isEmpty {
                CodeBlock(lines: comment.code, highlight: comment.highlight)
                    .background(Ink.bg000)
                rule(Ink.line, 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(comment.title).font(.sans(14, .semibold)).foregroundStyle(Ink.ink)
                SegmentedText(text: comment.body, color: Ink.inkMuted)
                if !comment.fixList.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(comment.fixList.count == 1 ? "fix" : "possible fixes").microLabel()
                        ForEach(Array(comment.fixList.enumerated()), id: \.offset) { _, fix in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("→").font(.mono(13)).foregroundStyle(Ink.brandText)
                                SegmentedText(text: fix)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                if let by = comment.foundBy, !by.isEmpty {
                    Text("found by " + by.joined(separator: ", ") + (comment.unchecked == true ? " · not checked — its checker didn't finish" : " · checked"))
                        .font(.mono(11)).foregroundStyle(comment.unchecked == true ? Ink.warning : Ink.inkMuted)
                        .padding(.top, 4)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))

            if !comment.context.isEmpty {
                rule(Ink.bg300, 1)
                context
            }

            rule(Ink.bg300, 1)
            chat
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .inkBox(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.bg200))
    }

    private func rule(_ color: Color, _ height: CGFloat) -> some View {
        Rectangle().fill(color).frame(height: height)
    }

    private var context: some View {
        let open = !reviews.closedContext.contains(key)
        return VStack(alignment: .leading, spacing: 16) {
            Button {
                if open { reviews.closedContext.insert(key) } else { reviews.closedContext.remove(key) }
            } label: {
                HStack {
                    Text("context \(settings.agent) pulled in · \(comment.context.count)").microLabel()
                    Spacer()
                    Text(open ? "hide" : "show").font(.sans(13, .semibold)).foregroundStyle(Ink.inkMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                ForEach(Array(comment.context.enumerated()), id: \.offset) { _, snippet in
                    VStack(alignment: .leading, spacing: 8) {
                        SegmentedText(text: snippet.why, size: 14)
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text(snippet.file).font(.mono(12, .medium)).foregroundStyle(Ink.ink)
                                Text(snippet.lines).font(.mono(12)).foregroundStyle(Ink.inkMuted)
                                Spacer(minLength: 0)
                                Text(snippet.tag).font(.sans(11.5, .semibold)).foregroundStyle(Ink.inkMuted)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Ink.bg300)
                            Rectangle().fill(Ink.line).frame(height: 1)
                            CodeBlock(lines: snippet.code, highlight: snippet.highlight, main: false)
                        }
                        .background(Ink.bg000)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .inkBox(8)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20))
    }

    private var chat: some View {
        let pending = reviews.pendingChats.contains(key)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(thread.enumerated()), id: \.offset) { _, message in
                switch message.role {
                case .user:
                    HStack {
                        Spacer(minLength: 120)
                        Text(message.text)
                            .font(.sans(14)).lineSpacing(4).foregroundStyle(Ink.ink)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 4, topTrailingRadius: 12, style: .continuous).fill(Ink.bg300))
                            .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 4, topTrailingRadius: 12, style: .continuous).strokeBorder(Ink.line, lineWidth: Ink.border))
                    }
                case .assistant:
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.agent).font(.mono(11)).foregroundStyle(Ink.inkMuted)
                        SegmentedText(text: message.text, size: 14)
                    }
                    .padding(.trailing, 60)
                case .error:
                    Text(message.text).font(.sans(13)).foregroundStyle(Ink.danger)
                }
            }

            if pending {
                Dots(text: "\(settings.agent) is thinking").font(.mono(12)).foregroundStyle(Ink.inkMuted)
            }

            if thread.isEmpty && !pending && !comment.asks.isEmpty {
                HStack(spacing: 8) {
                    ForEach(comment.asks, id: \.self) { question in
                        Button(question) { reviews.ask(pr, comment: index, question) }
                            .buttonStyle(ChipButtonStyle())
                    }
                }
            }

            HStack(spacing: 8) {
                InkField(placeholder: "ask \(settings.agent) about this comment", text: draft) {
                    reviews.ask(pr, comment: index, draft.wrappedValue)
                }
                Button("ask") { reviews.ask(pr, comment: index, draft.wrappedValue) }
                    .buttonStyle(HardButtonStyle())
                    .disabled(pending)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
    }

    private var draft: Binding<String> {
        Binding(get: { reviews.drafts[key] ?? "" }, set: { reviews.drafts[key] = $0 })
    }
}
