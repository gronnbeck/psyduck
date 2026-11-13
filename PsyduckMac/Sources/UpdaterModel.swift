import Combine
import Foundation
import Sparkle

/// Wraps Sparkle so the rest of the app can offer "Check for Updates…" without
/// knowing whether updates are configured at all.
///
/// A local development build has an empty `SUFeedURL` — CI stamps the real one
/// in per channel at build time. Starting Sparkle with no feed makes it report
/// errors the developer can do nothing about, so the updater simply isn't
/// created and the menu item stays disabled.
@MainActor
final class UpdaterModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController?

    /// Which channel this build follows, stamped in by CI. Nil for local builds.
    let channel: String?

    var isConfigured: Bool { controller != nil }

    init(info: [String: Any]? = Bundle.main.infoDictionary) {
        channel = info?["PsyduckChannel"] as? String

        let feedURL = info?["SUFeedURL"] as? String ?? ""
        guard !feedURL.isEmpty else {
            controller = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller

        // Sparkle disables checking while one is already running; mirroring it
        // keeps the menu item from offering a check that would be ignored.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Shown on screen, so a tester can report which build they are on.
    var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        if let channel {
            return "\(short) (\(build)) · \(channel)"
        }
        return "\(short) (\(build)) · local build"
    }
}
