import SwiftUI

@main
struct PsyduckApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: AppStore
    @StateObject private var updater = UpdaterModel()

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: AppStore(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ShellView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(updater)
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
            // ⌘, opens settings inside the main window, not a separate one.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
