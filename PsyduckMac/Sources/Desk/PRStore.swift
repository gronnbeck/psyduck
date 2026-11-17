import Foundation

@MainActor
final class PRStore: ObservableObject {
    @Published var lists = PRLists()
    @Published private(set) var syncing = false
    @Published var syncedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var approving: Set<DeskPullRequest.ID> = []
    @Published private(set) var approveErrors: [DeskPullRequest.ID: String] = [:]
    /// Approvals made from desk, by the commit they approved — an approved
    /// PR drops off the review list, so this is what remembers it.
    @Published private(set) var approvals: [DeskPullRequest.ID: String] = [:]
    /// An "approve all" in progress or just finished.
    @Published private(set) var bulk: Bulk?
    /// What an "approve all" has still to get to, in order.
    @Published private(set) var queued: [DeskPullRequest.ID] = []

    struct Bulk: Equatable {
        var done = 0
        var failed = 0
        let total: Int
        var running: Bool { done + failed < total }
    }

    private let settings: DeskSettings
    private var timer: Timer?

    init(settings: DeskSettings) {
        self.settings = settings
    }

    var all: [DeskPullRequest] { lists.review + lists.mine }

    func find(_ id: DeskPullRequest.ID) -> DeskPullRequest? {
        all.first { $0.id == id }
    }

    func isMine(_ pr: DeskPullRequest) -> Bool {
        lists.mine.contains { $0.id == pr.id }
    }

    /// The commit you approved last, from desk or from github.
    func approvedSha(_ pr: DeskPullRequest) -> String? {
        approvals[pr.id] ?? pr.approvedSha
    }

    func isApproved(_ pr: DeskPullRequest) -> Bool {
        !pr.headSha.isEmpty && approvedSha(pr) == pr.headSha
    }

    /// Approves on GitHub, only when you press the button: `gh pr review --approve`, as you. Refuses if the PR has moved
    /// on since you looked, so you never approve commits you haven't seen.
    @discardableResult
    func approve(_ pr: DeskPullRequest, refreshing: Bool = true) async -> Bool {
        guard !approving.contains(pr.id) else { return false }
        approving.insert(pr.id)
        approveErrors[pr.id] = nil
        defer { approving.remove(pr.id) }
        do {
            let gh = try settings.gh()
            let head = try await Shell.run(gh, ["pr", "view", String(pr.number), "--repo", pr.repo, "--json", "headRefOid", "--jq", ".headRefOid"])
            guard head.ok else { throw PRError.tool("gh", head.failureLine) }
            let current = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard pr.headSha.isEmpty || current == pr.headSha else {
                approveErrors[pr.id] = "new commits landed since desk last synced. nothing was approved — have a look first."
                if refreshing { await refresh() }
                return false
            }
            let result = try await Shell.run(gh, ["pr", "review", String(pr.number), "--repo", pr.repo, "--approve"])
            guard result.ok else { throw PRError.tool("gh", result.failureLine) }
            approvals[pr.id] = current
            if refreshing { await refresh() }
            return true
        } catch {
            approveErrors[pr.id] = error.localizedDescription
            return false
        }
    }

    /// The same approval, for each PR the user confirmed, one after another —
    /// each still checked against the commit it was reviewed at.
    /// Where a PR is in an approve-all: approving now, waiting its turn, done
    /// or failed. nil when it isn't part of one.
    enum Approval: Equatable { case approving, waiting(Int), approved, failed(String) }

    func approval(_ pr: DeskPullRequest) -> Approval? {
        if approving.contains(pr.id) { return .approving }
        if let place = queued.firstIndex(of: pr.id) { return .waiting(place + 1) }
        if let error = approveErrors[pr.id] { return .failed(error) }
        if approvals[pr.id] == pr.headSha, !pr.headSha.isEmpty { return .approved }
        return nil
    }

    /// Puts an approve-all in a given state without running it — for
    /// rendering screens.
    func show(approving: [DeskPullRequest.ID], queued: [DeskPullRequest.ID], approved: [DeskPullRequest]) {
        self.approving = Set(approving)
        self.queued = queued
        for pr in approved { approvals[pr.id] = pr.headSha }
        bulk = Bulk(done: approved.count, total: approved.count + approving.count + queued.count)
    }

    func approveAll(_ prs: [DeskPullRequest]) async {
        guard bulk?.running != true, !prs.isEmpty else { return }
        bulk = Bulk(total: prs.count)
        queued = prs.map(\.id)
        for pr in prs {
            queued.removeAll { $0 == pr.id }
            if await approve(pr, refreshing: false) { bulk?.done += 1 } else { bulk?.failed += 1 }
        }
        await refresh()
    }

    /// Refreshes now and then every five minutes, so the counts in the
    /// sidebar stay roughly true without anyone pressing refresh.
    func start() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            switch settings.source {
            case .gh: lists = try await GhPullRequests.fetch(gh: settings.gh())
            case .claude: lists = try await ClaudePullRequests.fetch(claude: settings.claude())
            }
            syncedAt = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// "2h", "5h", "1d" — how the design writes how long ago something was.
enum Ago {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(86400 * 30): return "\(Int(seconds / 86400))d"
        default: return "\(Int(seconds / (86400 * 30)))mo"
        }
    }

    /// "just now", "2 min ago" — for the last sync.
    static func long(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86400)) d ago"
        }
    }
}
