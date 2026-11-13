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
                .frame(minWidth: 1000, minHeight: 620)
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
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(updater)
        }
    }
}
