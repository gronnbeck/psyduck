import SwiftUI

@main
struct PsyduckApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: AppStore
    @StateObject private var updater = UpdaterModel()
    // Desk (pull requests and reviews).
    @StateObject private var deskSettings: DeskSettings
    @StateObject private var desk = DeskModel()
    @StateObject private var prs: PRStore
    @StateObject private var reviews: ReviewStore
    @StateObject private var drafts: DraftStore
    @AppStorage(AppMode.defaultsKey) private var mode: AppMode = .code

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: AppStore(settings: settings))

        // Tests host the app; they shouldn't read another app's data.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            TsukueImport.runOnce()
        }
        let deskSettings = DeskSettings()
        _deskSettings = StateObject(wrappedValue: deskSettings)
        _prs = StateObject(wrappedValue: PRStore(settings: deskSettings))
        _reviews = StateObject(wrappedValue: ReviewStore(settings: deskSettings))
        _drafts = StateObject(wrappedValue: DraftStore(settings: deskSettings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(updater)
                .environmentObject(deskSettings)
                .environmentObject(desk)
                .environmentObject(prs)
                .environmentObject(reviews)
                .environmentObject(drafts)
                .frame(minWidth: 1080, minHeight: 640)
                .task {
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                        await settings.detectMissing()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            // ⌘, opens settings inside the main window, not a separate one:
            // each app has its own page.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    switch mode {
                    case .code: store.showingSettings = true
                    case .desk: desk.route = .settings
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(before: .sidebar) {
                Button("Code") { mode = .code }.keyboardShortcut(AppMode.code.shortcut, modifiers: .command)
                Button("Desk") { mode = .desk }.keyboardShortcut(AppMode.desk.shortcut, modifiers: .command)
                Divider()
            }
        }
    }
}
