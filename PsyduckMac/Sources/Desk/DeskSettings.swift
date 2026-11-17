import Foundation
import PsyduckCore
import SwiftUI

/// Which tool finds the pull requests.
enum PRSource: String, CaseIterable {
    case gh, claude
}

/// A line of a tool test's output, coloured by outcome.
struct OutputLine: Identifiable, Equatable {
    enum Tone { case ok, bad, dim }

    let id = UUID()
    let text: String
    let tone: Tone

    static func == (a: OutputLine, b: OutputLine) -> Bool { a.text == b.text && a.tone == b.tone }
}

/// Settings are saved as you type — there is no save button anywhere.
@MainActor
final class DeskSettings: ObservableObject {
    @Published var source: PRSource { didSet { defaults.set(source.rawValue, forKey: Keys.source) } }
    @Published var ghPath: String { didSet { defaults.set(ghPath, forKey: Keys.ghPath) } }
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: Keys.claudePath) } }
    /// Review requests get a claude review as they arrive, and another when
    /// new commits land.
    @Published var autoReview: Bool { didSet { defaults.set(autoReview, forKey: Keys.autoReview) } }
    /// What the UI calls the reviewer. Just a name: it's still claude.
    @Published var agentName: String { didSet { defaults.set(agentName, forKey: Keys.agentName) } }
    /// How drafted comments for GitHub should sound, in the user's words.
    @Published var reviewTone: String { didSet { defaults.set(reviewTone, forKey: Keys.reviewTone) } }
    /// The review prompt template. Kept only when it differs from the
    /// default, so a better default reaches everyone who hasn't edited it.
    @Published var reviewPrompt: String {
        didSet {
            if reviewPrompt == ReviewStore.defaultReviewPrompt || reviewPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.removeObject(forKey: Keys.reviewPrompt)
            } else {
                defaults.set(reviewPrompt, forKey: Keys.reviewPrompt)
            }
        }
    }

    /// The model each stage of a review runs on; "" leaves it to claude.
    @Published var stageModels: [ReviewStage: String] {
        didSet { defaults.set(Dictionary(uniqueKeysWithValues: stageModels.map { ($0.key.rawValue, $0.value) }), forKey: Keys.stageModels) }
    }
    /// How many claude processes reviews may run at once, all reviews
    /// together. 0 means no limit.
    @Published var maxAgents: Int { didSet { defaults.set(maxAgents, forKey: Keys.maxAgents) } }
    /// Specialists switched off in settings, by id.
    @Published var specialistsOff: Set<String> { didSet { defaults.set(Array(specialistsOff).sorted(), forKey: Keys.specialistsOff) } }

    @Published private(set) var output: [String: [OutputLine]] = [:]
    @Published private(set) var testing: Set<String> = []

    private let defaults: UserDefaults

    /// Under `desk.` so they don't meet psyduck's own settings, which live
    /// in the same defaults.
    enum Keys {
        static let source = "desk.source"
        static let ghPath = "desk.ghPath"
        static let claudePath = "desk.claudePath"
        static let autoReview = "desk.autoReview"
        static let agentName = "desk.agentName"
        static let reviewPrompt = "desk.reviewPrompt"
        static let reviewTone = "desk.reviewTone"
        static let stageModels = "desk.stageModels"
        static let maxAgents = "desk.maxAgents"
        static let specialistsOff = "desk.specialistsOff"
        static let all = [source, ghPath, claudePath, autoReview, agentName, reviewPrompt,
                          reviewTone, stageModels, maxAgents, specialistsOff]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        source = PRSource(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .gh
        ghPath = defaults.string(forKey: Keys.ghPath) ?? ""
        claudePath = defaults.string(forKey: Keys.claudePath) ?? ""
        autoReview = defaults.object(forKey: Keys.autoReview) as? Bool ?? true
        agentName = defaults.string(forKey: Keys.agentName) ?? ""
        reviewTone = defaults.string(forKey: Keys.reviewTone) ?? ""
        reviewPrompt = defaults.string(forKey: Keys.reviewPrompt) ?? ReviewStore.defaultReviewPrompt
        let stored = defaults.dictionary(forKey: Keys.stageModels) as? [String: String] ?? [:]
        stageModels = Dictionary(uniqueKeysWithValues: ReviewStage.allCases.map { ($0, stored[$0.rawValue] ?? $0.defaultModel) })
        maxAgents = defaults.object(forKey: Keys.maxAgents) as? Int ?? 4
        specialistsOff = Set(defaults.stringArray(forKey: Keys.specialistsOff) ?? [])
    }

    func model(_ stage: ReviewStage) -> String { stageModels[stage] ?? stage.defaultModel }

    var specialists: [Specialist] { Specialist.all.filter { !specialistsOff.contains($0.id) } }

    /// nil when there's no limit.
    var agentLimit: Int? { maxAgents > 0 ? maxAgents : nil }

    /// The reviewer's name as shown, "claude" unless renamed.
    var agent: String {
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "claude" : name
    }

    /// The template reviews run with: an emptied field means the default.
    var reviewTemplate: String {
        reviewPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ReviewStore.defaultReviewPrompt : reviewPrompt
    }

    var reviewPromptIsDefault: Bool {
        reviewPrompt == ReviewStore.defaultReviewPrompt
    }

    /// Fills in any empty tool path on first launch, so settings show where
    /// each tool really is instead of a guess.
    func detectMissing() async {
        if ghPath.isEmpty, let found = await Shell.detect("gh") { ghPath = found }
        if claudePath.isEmpty, let found = await Shell.detect("claude") { claudePath = found }
    }

    func gh() throws -> String { try Shell.resolve("gh", configured: ghPath) }
    func claude() throws -> String { try Shell.resolve("claude", configured: claudePath) }

    func detect(_ tool: String) async {
        output[tool] = nil
        guard let found = await Shell.detect(tool) else {
            output[tool] = [OutputLine(text: "✗ couldn't find \(tool) on this mac.", tone: .bad)]
            return
        }
        if tool == "gh" { ghPath = found } else { claudePath = found }
    }

    func test(_ tool: String) async {
        testing.insert(tool)
        output[tool] = nil
        defer { testing.remove(tool) }
        output[tool] = tool == "gh" ? await testGh() : await testClaude()
    }

    private func testGh() async -> [OutputLine] {
        guard let path = try? gh() else { return [OutputLine(text: "✗ no path set. try detect.", tone: .bad)] }
        guard let version = try? await Shell.run(path, ["--version"]), version.ok else {
            return [OutputLine(text: "✗ nothing executable at \(path)", tone: .bad)]
        }
        var lines = [OutputLine(text: "✓ " + firstLine(version.stdout), tone: .ok)]
        if let user = try? await Shell.run(path, ["api", "user", "--jq", ".login"]), user.ok {
            lines.append(OutputLine(text: "✓ logged in to github.com as \(firstLine(user.stdout))", tone: .ok))
        } else {
            lines.append(OutputLine(text: "✗ not logged in. run gh auth login in a terminal.", tone: .bad))
            return lines
        }
        if let lists = try? await GhPullRequests.fetch(gh: path) {
            lines.append(OutputLine(text: "  \(lists.review.count) review requests · \(lists.mine.count) authored", tone: .dim))
        }
        return lines
    }

    private func testClaude() async -> [OutputLine] {
        guard let path = try? claude() else { return [OutputLine(text: "✗ no path set. try detect.", tone: .bad)] }
        guard let version = try? await Shell.run(path, ["--version"]), version.ok else {
            return [OutputLine(text: "✗ nothing executable at \(path)", tone: .bad)]
        }
        var lines = [OutputLine(text: "✓ claude " + firstLine(version.stdout).replacingOccurrences(of: " (Claude Code)", with: ""), tone: .ok)]
        // Reviews have claude run gh itself, through the same PATH desk gives it.
        if (try? gh()) != nil {
            lines.append(OutputLine(text: "✓ gh is there for claude to use", tone: .ok))
        } else {
            lines.append(OutputLine(text: "✗ claude can't find gh — reviews need it", tone: .bad))
        }
        return lines
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    /// The commands the current source runs, as shown in settings.
    var commands: [String] {
        switch source {
        case .gh:
            let gh = ghPath.isEmpty ? "gh" : ghPath
            return [
                "\(gh) api graphql -f query=… -F review='\(GhPullRequests.reviewQuery)'",
                "\(gh) api graphql -f query=… -F mine='\(GhPullRequests.mineQuery)'"
            ]
        case .claude:
            let claude = claudePath.isEmpty ? "claude" : claudePath
            return ["\(claude) -p \"list my open PRs: review requested + authored by me, as JSON\" --output-format json"]
        }
    }
}
