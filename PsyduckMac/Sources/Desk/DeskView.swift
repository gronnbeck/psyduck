import SwiftUI

/// Where the main pane is.
enum Route: Hashable {
    case all, review, mine, settings
    indirect case pr(DeskPullRequest, from: Route)

    /// The sidebar item that lights up — a PR keeps the list it came from lit.
    var nav: Route {
        if case .pr(_, let from) = self { return from }
        return self
    }

    var title: String {
        switch self {
        case .all: return "everything"
        case .review: return "review requested"
        case .mine: return "created by me"
        case .settings: return "settings"
        case .pr(let pr, _): return pr.title
        }
    }

    var isList: Bool { self == .all || self == .review || self == .mine }
}

@MainActor
final class DeskModel: ObservableObject {
    @Published var route: Route = .all

    func open(_ pr: DeskPullRequest) {
        route = .pr(pr, from: route.nav)
    }
}

struct DeskView: View {
    @EnvironmentObject private var app: DeskModel

    var body: some View {
        HStack(spacing: 0) {
            DeskSidebar()
                .frame(width: 232)
            Rectangle().fill(Ink.line).frame(width: Ink.border)
            MainPane()
        }
        .background(Ink.bg000)
        .ignoresSafeArea()
    }
}

// MARK: DeskSidebar

struct DeskSidebar: View {
    @EnvironmentObject private var app: DeskModel
    @EnvironmentObject private var prs: PRStore
    @EnvironmentObject private var settings: DeskSettings
    @EnvironmentObject private var reviews: ReviewStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights sit over the mode rail and reach a little
            // into this corner.
            Color.clear.frame(height: 36)

            HStack(spacing: 10) {
                Text("机")
                    .font(.jp(18, .bold))
                    .foregroundStyle(Ink.onBrand)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.brand))
                    .keyLedge(6, color: Ink.brandLedge)
                VStack(alignment: .leading, spacing: 1) {
                    (Text("desk").foregroundStyle(Ink.ink) + Text(".").foregroundStyle(Ink.brandText))
                        .font(.display(18)).tracking(-0.2)
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · your desk").font(.mono(11)).foregroundStyle(Ink.inkMuted)
                }
            }
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 24, trailing: 8))

            Text("pull requests").microLabel().padding(EdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 10))

            VStack(spacing: 2) {
                NavItem(route: .all, icon: "tray", label: "everything", count: prs.all.count)
                NavItem(route: .review, icon: "eye", label: "review requested", count: prs.lists.review.count)
                NavItem(route: .mine, icon: "arrow.triangle.branch", label: "created by me", count: prs.lists.mine.count)
            }

            Spacer(minLength: 0)

            NavItem(route: .settings, icon: "slider.horizontal.3", label: "settings", count: nil)

            HStack(spacing: 8) {
                Dot(color: prs.error == nil ? Ink.success : Ink.danger, size: 8)
                Text("via \(settings.source.rawValue)").font(.mono(11)).foregroundStyle(Ink.inkMuted)
                if let id = reviews.backgroundRun {
                    PulseDot(color: Ink.info, pulsing: true, size: 6)
                    Text("reviewing #\(id.split(separator: "#").last ?? "")")
                        .font(.mono(11)).foregroundStyle(Ink.inkMuted).lineLimit(1)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 0, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
            .padding(.top, 12)
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 16, trailing: 12))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ink.bg100)
    }
}

private struct NavItem: View {
    @EnvironmentObject private var app: DeskModel
    let route: Route
    let icon: String
    let label: String
    let count: Int?

    @State private var hovering = false

    /// Tinker's selected row: a raised wash and the lime bar on the left edge.
    var body: some View {
        let active = app.route.nav == route
        Button { app.route = route } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).frame(width: 18)
                    .foregroundStyle(active ? Ink.ink : Ink.inkMuted)
                Text(label).font(.sans(13, active ? .semibold : .medium)).frame(maxWidth: .infinity, alignment: .leading)
                if let count {
                    Text(String(count))
                        .font(.mono(11, .medium))
                        .foregroundStyle(Ink.inkMuted)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 18)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(active ? Ink.bg200 : Ink.bg300))
                }
            }
            .foregroundStyle(active || hovering ? Ink.ink : Ink.inkMuted)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? Ink.bg300 : hovering ? Ink.bg200 : .clear))
            .overlay(alignment: .leading) {
                if active { Capsule().fill(Ink.brand).frame(width: 3).padding(.vertical, 7).offset(x: -6) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.08), value: active)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Main pane

struct MainPane: View {
    @EnvironmentObject private var app: DeskModel
    @EnvironmentObject private var prs: PRStore
    @EnvironmentObject private var settings: DeskSettings
    @EnvironmentObject private var reviews: ReviewStore

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(EdgeInsets(top: 28, leading: 40, bottom: 20, trailing: 40))
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 1) }

            ScrollView {
                content
                    .padding(EdgeInsets(top: 28, leading: 40, bottom: 40, trailing: 40))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(app.route)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.bg000)
    }

    @ViewBuilder private var content: some View {
        switch app.route {
        case .all, .review, .mine: PRListsView(route: app.route)
        case .settings: SettingsPane()
        case .pr(let pr, _): PRDetailView(pr: live(pr))
        }
    }

    /// The route keeps the PR as it was when opened; syncs bring new commits.
    private func live(_ pr: DeskPullRequest) -> DeskPullRequest {
        prs.find(pr.id) ?? pr
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .pr(_, let from) = app.route {
                Button("← \(from.title)") { app.route = from }
                    .buttonStyle(GhostButtonStyle(size: 13, color: Ink.inkMuted))
                    .padding(EdgeInsets(top: -8, leading: -12, bottom: 0, trailing: 0))
            }
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    if case .pr(let snapshot, _) = app.route {
                        let pr = live(snapshot)
                        HStack(spacing: 10) {
                            Text(pr.ref).font(.mono(12)).foregroundStyle(Ink.inkMuted)
                            PRStatusBadge(status: pr.status)
                        }
                    }
                    Text(app.route.title)
                        .font(.display(26))
                        .tracking(-0.3)
                        .foregroundStyle(Ink.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    subtitle
                }
                Spacer(minLength: 0)
                actions
            }
        }
    }

    @ViewBuilder private var subtitle: some View {
        Group {
            switch app.route {
            case .settings:
                Text("saved as you type.")
            case .pr(let snapshot, _):
                let pr = live(snapshot)
                Text("\(pr.author) wants to merge \(pr.headRef) into \(pr.baseRef) · +\(pr.additions) −\(pr.deletions) · \(pr.checks.label) · \(Ago.short(pr.updatedAt))")
            default:
                if let bulk = prs.bulk, bulk.running {
                    Dots(text: "approving \(bulk.done + bulk.failed + 1) of \(bulk.total)")
                } else if prs.syncing {
                    Dots(text: "syncing via \(settings.source.rawValue)")
                } else if let bulk = prs.bulk, bulk.failed > 0 {
                    Text("approved \(bulk.done) of \(bulk.total) · \(bulk.failed) didn't go through — open \(bulk.failed == 1 ? "it" : "them") to see why")
                        .foregroundStyle(Ink.danger)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in Text(listSubtitle) }
                }
            }
        }
        .font(.sans(13))
        .foregroundStyle(Ink.inkMuted)
        .lineLimit(1)
    }

    private var listSubtitle: String {
        let n: Int
        switch app.route {
        case .review: n = prs.lists.review.count
        case .mine: n = prs.lists.mine.count
        default: n = prs.all.count
        }
        let synced = prs.syncedAt.map { "synced \(Ago.long($0))" } ?? "not synced yet"
        return "\(n) open pull request\(n == 1 ? "" : "s") · \(synced) via \(settings.source.rawValue)"
    }

    @ViewBuilder private var actions: some View {
        switch app.route {
        case .pr(let snapshot, _):
            let pr = live(snapshot)
            HStack(spacing: 8) {
                Button("open on github ↗") {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(GhostButtonStyle())
                ReviewButton(pr: pr)
                ApproveButton(pr: pr)
            }
        case .all, .review, .mine:
            HStack(spacing: 8) {
            if app.route != .mine { ApproveAllMenu() }
            Button {
                Task { await prs.refresh() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    Text("refresh")
                }
            }
            .buttonStyle(HardButtonStyle(kind: .outlined))
            .disabled(prs.syncing)
            }
        case .settings:
            EmptyView()
        }
    }
}

/// "…" → approve everything the reviewer would approve, after one look at
/// the list. Only PRs whose review is of the commit they're at now, with
/// nothing failing.
struct ApproveAllMenu: View {
    @EnvironmentObject private var prs: PRStore
    @EnvironmentObject private var reviews: ReviewStore
    @EnvironmentObject private var settings: DeskSettings
    @State private var open = false
    @State private var confirming = false

    var body: some View {
        let eligible = Self.eligible(prs.lists.review, prs: prs, reviews: reviews)
        Button { open = true } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).frame(height: 17)
        }
        .buttonStyle(HardButtonStyle(kind: .outlined))
        .disabled(prs.bulk?.running == true)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            let leftOut = Self.leftOut(prs.lists.review, prs: prs, reviews: reviews)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    open = false
                    confirming = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle").font(.system(size: 13, weight: .semibold))
                        Text("approve all \(settings.agent) would approve").font(.sans(14, .semibold)).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(String(eligible.count)).font(.mono(12, .medium)).foregroundStyle(Ink.inkMuted)
                    }
                    .foregroundStyle(eligible.isEmpty ? Ink.inkFaint : Ink.ink)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(eligible.isEmpty)
                Text(eligible.isEmpty && leftOut.isEmpty
                     ? "nothing \(settings.agent) would approve is waiting on you."
                     : "only reviews of the latest commit, with checks passing.")
                    .font(.sans(12)).foregroundStyle(Ink.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                if !leftOut.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("left out").microLabel()
                        ForEach(leftOut, id: \.0.id) { pr, why in
                            HStack(spacing: 8) {
                                Text(pr.ref).font(.mono(12)).foregroundStyle(Ink.inkMuted).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(why).font(.sans(12)).foregroundStyle(Ink.inkMuted).lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.top, 8)
                    .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
                }
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 14, trailing: 8))
            .frame(width: 380)
            .background(Ink.bg200)
        }
        .confirmationDialog("approve \(eligible.count) pull request\(eligible.count == 1 ? "" : "s") on github?", isPresented: $confirming) {
            Button("approve \(eligible.count)") { Task { await prs.approveAll(eligible) } }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(Self.summary(eligible, agent: settings.agent))
        }
    }

    static func eligible(_ list: [DeskPullRequest], prs: PRStore, reviews: ReviewStore) -> [DeskPullRequest] {
        list.filter { wouldApprove($0, prs: prs, reviews: reviews) && reason($0, reviews: reviews) == nil }
    }

    /// PRs the reviewer would approve that approve-all still skips, and why.
    static func leftOut(_ list: [DeskPullRequest], prs: PRStore, reviews: ReviewStore) -> [(DeskPullRequest, String)] {
        list.compactMap { pr in
            guard wouldApprove(pr, prs: prs, reviews: reviews), let why = reason(pr, reviews: reviews) else { return nil }
            return (pr, why)
        }
    }

    private static func wouldApprove(_ pr: DeskPullRequest, prs: PRStore, reviews: ReviewStore) -> Bool {
        reviews.record(pr)?.review.verdict == .approve && !prs.isMine(pr) && !prs.isApproved(pr)
    }

    private static func reason(_ pr: DeskPullRequest, reviews: ReviewStore) -> String? {
        if reviews.isRunning(pr) { return "being reviewed again" }
        if reviews.isOutdated(pr) || pr.headSha.isEmpty { return "review is of an older commit" }
        if pr.status == .draft { return "draft" }
        switch pr.checks {
        case .failing: return "checks failing"
        case .pending: return "checks still running"
        case .passing, .none: return nil
        }
    }

    static func summary(_ eligible: [DeskPullRequest], agent: String) -> String {
        let shown = eligible.prefix(12).map { "\($0.ref) — \($0.title)" }
        let more = eligible.count > 12 ? ["and \(eligible.count - 12) more"] : []
        return (["\(agent) would approve each of these:"] + shown + more + ["this posts an approval to github as you, for each one."])
            .joined(separator: "\n")
    }
}

// MARK: PR presentation

extension DeskPullRequest.Checks {
    var label: String {
        switch self {
        case .passing: return "checks passing"
        case .failing: return "checks failing"
        case .pending: return "checks running"
        case .none: return "no checks"
        }
    }

    var color: Color {
        switch self {
        case .passing: return Ink.success
        case .failing: return Ink.danger
        case .pending: return Ink.warning
        case .none: return Ink.bg300
        }
    }
}

struct PRStatusBadge: View {
    let status: DeskPullRequest.Status

    var body: some View {
        switch status {
        case .review: Badge(text: "review required", dot: Ink.warning)
        case .draft: Badge(text: "draft", dot: Ink.inkFaint)
        case .changes: Badge(text: "changes requested", dot: Ink.danger)
        case .approved: Badge(text: "approved", dot: Ink.success)
        }
    }
}

// MARK: Lists

struct PRListsView: View {
    @EnvironmentObject private var prs: PRStore
    let route: Route

    var body: some View {
        let review = route == .mine ? [] : prs.lists.review
        let mine = route == .review ? [] : prs.lists.mine

        VStack(alignment: .leading, spacing: 36) {
            if let error = prs.error {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("couldn't load your pull requests").font(.sans(14, .semibold)).foregroundStyle(Ink.danger)
                        Text(error).font(.mono(12)).foregroundStyle(Ink.inkMuted).textSelection(.enabled)
                    }
                }
            }

            if review.isEmpty && mine.isEmpty {
                if prs.error == nil && prs.syncedAt != nil { AllClear() }
            } else {
                if route != .mine && !review.isEmpty {
                    PRSection(title: "review requested", note: "you're a requested reviewer", items: review, mine: false)
                }
                if route != .review && !mine.isEmpty {
                    PRSection(title: "created by me", note: "open, authored by you", items: mine, mine: true)
                }
            }
        }
    }
}

private struct AllClear: View {
    var body: some View {
        VStack(spacing: 10) {
            (Text("all clear").foregroundStyle(Ink.ink) + Text(".").foregroundStyle(Ink.brandText))
                .font(.display(40))
                .tracking(-0.8)
            Text("nothing needs you right now. that's fine.")
                .font(.sans(14))
                .foregroundStyle(Ink.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

private struct PRSection: View {
    let title: String
    let note: String
    let items: [DeskPullRequest]
    let mine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, count: items.count, note: note)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, pr in
                    PRRow(pr: pr, mine: mine)
                        .overlay(alignment: .top) {
                            if index > 0 { Rectangle().fill(Ink.line).frame(height: 1) }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .inkBox(12, fill: .clear)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.bg200))
        }
    }
}

private struct PRRow: View {
    @EnvironmentObject private var app: DeskModel
    let pr: DeskPullRequest
    let mine: Bool
    @State private var hovering = false

    var body: some View {
        Button { app.open(pr) } label: {
            HStack(spacing: 20) {
                Dot(color: pr.checks.color).help(pr.checks.label).frame(width: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pr.title)
                        .font(.sans(14, .semibold))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(pr.ref).font(.mono(12)).foregroundStyle(Ink.inkMuted)
                        Text("·")
                        Text(mine ? pr.reviewersLabel : pr.author)
                        Text("·")
                        Text(pr.checks.label)
                    }
                    .font(.sans(13))
                    .foregroundStyle(Ink.inkMuted)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text("+\(pr.additions)").foregroundStyle(Ink.inkMuted)
                    Text("−\(pr.deletions)").foregroundStyle(Ink.danger)
                }
                .font(.mono(12))
                .fixedSize()
                ReviewTag(pr: pr)
                PRStatusBadge(status: pr.status)
                Text(Ago.short(pr.updatedAt))
                    .font(.mono(12))
                    .foregroundStyle(Ink.inkMuted)
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(hovering ? Ink.bg300 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// What claude made of a PR, at a glance: its call, or that the call is stale.
private struct ReviewTag: View {
    @EnvironmentObject private var reviews: ReviewStore
    @EnvironmentObject private var settings: DeskSettings
    @EnvironmentObject private var prs: PRStore

    let pr: DeskPullRequest

    var body: some View {
        switch prs.approval(pr) {
        case .approving?:
            Badge(text: "approving", dot: Ink.info, pulsing: true)
        case .waiting(let place)?:
            Badge(text: "waiting to approve · \(place)", dot: Ink.inkFaint)
        case .approved?:
            Badge(text: "✓ approved", dot: Ink.success)
        case .failed(let error)?:
            Badge(text: "didn't approve", dot: Ink.danger).help(error)
        case nil:
            verdict
        }
    }

    @ViewBuilder private var verdict: some View {
        if reviews.isRunning(pr) {
            Badge(text: "reviewing", dot: Ink.info, pulsing: true)
        } else if reviews.isOutdated(pr) {
            Badge(text: "review out of date", dot: Ink.warning)
        } else if let verdict = reviews.record(pr)?.review.verdict {
            Badge(text: "\(settings.agent): " + verdict.label, dot: verdict.dot)
        }
    }
}
