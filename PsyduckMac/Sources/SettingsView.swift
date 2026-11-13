import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updater: UpdaterModel

    @State private var claudeCheck: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section("claude") {
                HStack {
                    TextField("path to claude", text: $settings.claudePath, prompt: Text("~/.local/bin/claude"))
                        .font(.mono(12))
                    Button("detect") {
                        Task {
                            if let found = await Shell.detect("claude") { settings.claudePath = found }
                            await check()
                        }
                    }
                    Button("check") { Task { await check() } }
                }
                if let claudeCheck {
                    Text(claudeCheck).font(.mono(11)).foregroundStyle(Ink.ink3)
                }
                Picker("permissions", selection: $settings.permissionMode) {
                    ForEach(AppSettings.permissionModes, id: \.id) { mode in
                        Text(mode.label).tag(mode.id)
                    }
                }
                TextField("model", text: $settings.model, prompt: Text("claude's default"))
                    .font(.mono(12))
            }

            Section("git") {
                TextField("path to git", text: $settings.gitPath, prompt: Text("/usr/bin/git"))
                    .font(.mono(12))
                TextField("worktrees go in", text: $settings.workspacesRoot)
                    .font(.mono(12))
                TextField("cloned repos go in", text: $settings.reposRoot)
                    .font(.mono(12))
            }

            Section("about") {
                LabeledContent("version", value: updater.versionDescription)
                Button("check for updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
        .task { await check() }
    }

    private func check() async {
        do {
            let path = try settings.resolvedClaude()
            let result = try await Shell.run(path, ["--version"])
            claudeCheck = result.ok
                ? "✓ \(path) — \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
                : "✗ \(path): \(result.failureLine)"
        } catch {
            claudeCheck = "✗ \(error.localizedDescription)"
        }
    }
}
