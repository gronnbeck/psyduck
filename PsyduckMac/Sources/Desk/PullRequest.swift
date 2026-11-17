import Foundation

struct DeskPullRequest: Identifiable, Hashable, Codable {
    enum Checks: String, Codable { case passing, failing, pending, none }
    enum Status: String, Codable { case review, draft, changes, approved }

    let repo: String
    let number: Int
    let title: String
    let url: String
    let body: String
    let author: String
    let reviewers: [String]
    let checks: Checks
    let status: Status
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let updatedAt: Date
    let headRef: String
    let baseRef: String
    let headSha: String
    /// The commit you last approved, if your latest review is an approval.
    var approvedSha: String? = nil

    var id: String { "\(repo)#\(number)" }
    var ref: String { id }

    var reviewersLabel: String {
        reviewers.isEmpty ? "no reviewers yet" : reviewers.joined(separator: ", ")
    }
}

/// Both lists the app shows.
struct PRLists: Equatable {
    var review: [DeskPullRequest] = []
    var mine: [DeskPullRequest] = []
}

// MARK: gh

/// One GraphQL call through `gh api` gets everything a row needs — checks,
/// size and review state — which `gh search prs` can't.
enum GhPullRequests {
    static let reviewQuery = "is:pr is:open review-requested:@me archived:false"
    static let mineQuery = "is:pr is:open author:@me archived:false"

    static let graphql = """
    query($review: String!, $mine: String!) {
      review: search(query: $review, type: ISSUE, first: 50) { nodes { ...pr } }
      mine: search(query: $mine, type: ISSUE, first: 50) { nodes { ...pr } }
    }
    fragment pr on PullRequest {
      number title url body isDraft additions deletions changedFiles updatedAt
      headRefName baseRefName reviewDecision
      repository { nameWithOwner }
      author { login }
      reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
      commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
      viewerLatestReview { state commit { oid } }
    }
    """

    static func fetch(gh: String) async throws -> PRLists {
        let result = try await Shell.run(gh, [
            "api", "graphql",
            "-f", "query=\(graphql)",
            "-F", "review=\(reviewQuery)",
            "-F", "mine=\(mineQuery)"
        ])
        guard result.ok else { throw PRError.tool("gh", result.failureLine) }
        return try parse(Data(result.stdout.utf8))
    }

    static func parse(_ data: Data) throws -> PRLists {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw PRError.unreadable("gh")
        }
        guard let lists = response.data else {
            throw PRError.tool("gh", response.errors?.first?.message ?? "no data")
        }
        return PRLists(review: lists.review.nodes.compactMap(\.pullRequest),
                       mine: lists.mine.nodes.compactMap(\.pullRequest))
    }

    private struct Response: Decodable {
        struct Lists: Decodable { let review: Search; let mine: Search }
        struct Search: Decodable { let nodes: [Node] }
        struct Message: Decodable { let message: String }
        let data: Lists?
        let errors: [Message]?
    }

    private struct Node: Decodable {
        struct Repo: Decodable { let nameWithOwner: String }
        struct Login: Decodable { let login: String }
        struct Requests: Decodable { let nodes: [Request] }
        struct Request: Decodable { let requestedReviewer: Reviewer? }
        struct Reviewer: Decodable { let login: String?; let name: String? }
        struct Commits: Decodable { let nodes: [CommitNode] }
        struct CommitNode: Decodable { let commit: Commit }
        struct Commit: Decodable { let oid: String; let statusCheckRollup: Rollup? }
        struct Rollup: Decodable { let state: String }
        struct ViewerReview: Decodable { let state: String; let commit: Commit? }

        // Search results can include issues, which decode as empty objects.
        let number: Int?
        let title: String?
        let url: String?
        let body: String?
        let isDraft: Bool?
        let additions: Int?
        let deletions: Int?
        let changedFiles: Int?
        let updatedAt: String?
        let headRefName: String?
        let baseRefName: String?
        let reviewDecision: String?
        let repository: Repo?
        let author: Login?
        let reviewRequests: Requests?
        let commits: Commits?
        let viewerLatestReview: ViewerReview?

        var pullRequest: DeskPullRequest? {
            guard let number, let title, let repository else { return nil }
            let commit = commits?.nodes.last?.commit
            return DeskPullRequest(
                repo: repository.nameWithOwner,
                number: number,
                title: title,
                url: url ?? "https://github.com/\(repository.nameWithOwner)/pull/\(number)",
                body: body ?? "",
                author: author?.login ?? "ghost",
                reviewers: reviewRequests?.nodes.compactMap { $0.requestedReviewer?.login ?? $0.requestedReviewer?.name } ?? [],
                checks: Self.checks(commit?.statusCheckRollup?.state),
                status: Self.status(draft: isDraft ?? false, decision: reviewDecision),
                additions: additions ?? 0,
                deletions: deletions ?? 0,
                changedFiles: changedFiles ?? 0,
                updatedAt: updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast,
                headRef: headRefName ?? "",
                baseRef: baseRefName ?? "main",
                headSha: commit?.oid ?? "",
                approvedSha: viewerLatestReview?.state == "APPROVED" ? viewerLatestReview?.commit?.oid : nil)
        }

        static func checks(_ state: String?) -> DeskPullRequest.Checks {
            switch state {
            case "SUCCESS": return .passing
            case "FAILURE", "ERROR": return .failing
            case "PENDING", "EXPECTED": return .pending
            default: return .none
            }
        }

        static func status(draft: Bool, decision: String?) -> DeskPullRequest.Status {
            if draft { return .draft }
            switch decision {
            case "APPROVED": return .approved
            case "CHANGES_REQUESTED": return .changes
            default: return .review
            }
        }
    }
}

// MARK: claude

/// The slower, more flexible source: claude does the lookup with gh and
/// answers in a fixed JSON shape.
enum ClaudePullRequests {
    static let schema = """
    {"type":"object","required":["review","mine"],"properties":{
      "review":{"type":"array","items":{"$ref":"#/$defs/pr"}},
      "mine":{"type":"array","items":{"$ref":"#/$defs/pr"}}},
     "$defs":{"pr":{"type":"object","required":["repo","number","title","url","author","checks","status","additions","deletions","changedFiles","updatedAt","headRef","baseRef","headSha","body","reviewers"],
      "properties":{"repo":{"type":"string"},"number":{"type":"integer"},"title":{"type":"string"},"url":{"type":"string"},
       "body":{"type":"string"},"author":{"type":"string"},"reviewers":{"type":"array","items":{"type":"string"}},
       "checks":{"enum":["passing","failing","pending","none"]},"status":{"enum":["review","draft","changes","approved"]},
       "additions":{"type":"integer"},"deletions":{"type":"integer"},"changedFiles":{"type":"integer"},
       "updatedAt":{"type":"string","description":"ISO 8601"},"headRef":{"type":"string"},"baseRef":{"type":"string"},"headSha":{"type":"string"}}}}}
    """

    static let prompt = """
    List my open GitHub pull requests using the gh cli: those where my review is requested \
    (\(GhPullRequests.reviewQuery)) and those I authored (\(GhPullRequests.mineQuery)). \
    For each, report checks as passing/failing/pending/none from the latest commit's status rollup, \
    and status as draft, approved, changes (changes requested) or review. Read only — change nothing on GitHub.
    """

    static func fetch(claude: String) async throws -> PRLists {
        let result = try await Shell.run(claude, [
            "-p", prompt,
            "--output-format", "json",
            "--json-schema", schema,
            "--allowedTools", "Bash(gh search:*)", "Bash(gh pr view:*)", "Bash(gh pr list:*)", "Bash(gh api:*)",
            "--no-session-persistence"
        ], directory: ClaudeWorkspace.directory)
        guard result.ok else { throw PRError.tool("claude", result.failureLine) }
        return try parse(Data(result.stdout.utf8))
    }

    static func parse(_ data: Data) throws -> PRLists {
        struct Envelope: Decodable { let structured_output: Lists?; let result: String? }
        struct Lists: Decodable { let review: [DeskPullRequest]; let mine: [DeskPullRequest] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return ISO8601DateFormatter().date(from: text) ?? .distantPast
        }
        guard let envelope = try? decoder.decode(Envelope.self, from: data), let lists = envelope.structured_output else {
            throw PRError.unreadable("claude")
        }
        return PRLists(review: lists.review, mine: lists.mine)
    }
}

enum PRError: LocalizedError {
    case tool(String, String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tool(let tool, let line): return "\(tool) failed: \(line)"
        case .unreadable(let tool): return "couldn't read what \(tool) sent back."
        }
    }
}

/// An empty directory claude runs in, so a project's CLAUDE.md or settings
/// never leak into a review.
enum ClaudeWorkspace {
    static var directory: URL {
        let url = DeskFolder.directory.appendingPathComponent("claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Desk's folder in Application Support: `desk/` inside psyduck's, which is
/// per bundle identifier so the edge build and a local build never share state.
enum DeskFolder {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "lol.np.psyduck", isDirectory: true)
            .appendingPathComponent("desk", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
