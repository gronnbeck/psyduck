import AppKit
import Foundation
import PsyduckCore

/// The header's primary action: commit, push, pull, open or ready a PR. The
/// engine runs it; opening a PR in the browser is the only part done here.
extension AppStore {
    func primaryAction(for id: UUID) -> PrimaryAction {
        branches[id].map(PrimaryAction.decide) ?? .none
    }

    func refreshBranch(_ id: UUID, network: Bool) async {
        guard let state = await engine.branchState(id, network: network),
              workspaces.contains(where: { $0.id == id }) else { return }
        branches[id] = state
    }

    func perform(_ action: PrimaryAction, on id: UUID) {
        guard workspaces.contains(where: { $0.id == id }), !acting.contains(id) else { return }

        switch action {
        case .viewPR(let pr), .merged(let pr):
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            return
        case .none:
            return
        default:
            break
        }

        acting.insert(id)
        Task {
            await engine.perform(action, on: id)
            acting.remove(id)
            await refreshBranch(id, network: true)
            await refreshChanges(id)
        }
    }

    /// The panel's "Commit" button: commit everything, don't push.
    func commitOnly(_ id: UUID) {
        perform(.commit, on: id)
    }

    /// Throws away every uncommitted change, untracked files included.
    /// The view confirms first.
    func discard(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }), !acting.contains(id) else { return }
        acting.insert(id)
        Task {
            await engine.discard(id)
            acting.remove(id)
            await refreshBranch(id, network: false)
            await refreshChanges(id)
        }
    }
}
