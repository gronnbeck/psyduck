import SwiftUI

/// Settings, as a page inside the main window. It takes over the session and
/// changes panes; the sidebar stays.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updater: UpdaterModel
    @EnvironmentObject private var store: AppStore

    @State private var claudeCheck: String?
    @State private var claudeOK = true

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(leading: 12, trailing: 16) {
                Button { store.showingSettings = false } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.tkGhost)
                .keyboardShortcut(.escape, modifiers: [])
                Text("Settings").font(.sans(15, .semibold))
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Settings").font(.display(22))

                    section("Claude") {
                        row("Path to claude", hint: "The Claude Code CLI psyduck runs in each worktree.") {
                            HStack(spacing: 8) {
                                TkTextField(text: $settings.claudePath, placeholder: "~/.local/bin/claude")
                                Button("Detect") {
                                    Task {
                                        if let found = await Shell.detect("claude") { settings.claudePath = found }
                                        await check()
                                    }
                                }
                                .buttonStyle(.tkSecondary)
                                Button("Check") { Task { await check() } }
                                    .buttonStyle(.tkSecondary)
                            }
                            if let claudeCheck {
                                Text(claudeCheck)
                                    .font(.mono(12))
                                    .foregroundStyle(claudeOK ? Tk.success : Tk.danger)
                                    .textSelection(.enabled)
                            }
                        }
                        row("Permissions", hint: "What Claude may do without asking. The worktree keeps edits off your checkout, but it isn't a sandbox.") {
                            Picker("", selection: $settings.permissionMode) {
                                ForEach(AppSettings.permissionModes, id: \.id) { mode in
                                    Text(mode.label).tag(mode.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                            .font(.sans(13))
                        }
                        row("Model", hint: "An alias like opus or sonnet, or a full model name. Empty uses Claude's default.") {
                            TkTextField(text: $settings.model, placeholder: "Claude's default")
                        }
                    }

                    section("Git") {
                        row("Path to git", hint: nil) {
                            TkTextField(text: $settings.gitPath, placeholder: "/usr/bin/git")
                        }
                        row("Worktrees go in", hint: "Each workspace is <here>/<repo>/<name>.") {
                            TkTextField(text: $settings.workspacesRoot, placeholder: AppSettings.defaultWorkspacesRoot)
                        }
                        row("Cloned repos go in", hint: nil) {
                            TkTextField(text: $settings.reposRoot, placeholder: AppSettings.defaultReposRoot)
                        }
                    }

                    section("About") {
                        HStack {
                            Text(updater.versionDescription).font(.mono(12)).foregroundStyle(Tk.inkMuted)
                            Spacer()
                            Button("Check for updates") { updater.checkForUpdates() }
                                .buttonStyle(.tkSecondary)
                                .disabled(!updater.canCheckForUpdates)
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 32)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Tk.bg000)
        .task { await check() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sectionLabel()
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tkCard(Tk.radiusLg, fill: Tk.bg100)
        }
    }

    private func row<Content: View>(_ label: String, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.sans(13, .semibold))
            if let hint {
                Text(hint).font(.sans(12)).foregroundStyle(Tk.inkMuted)
            }
            content()
        }
    }

    private func check() async {
        do {
            let path = try settings.resolvedClaude()
            let result = try await Shell.run(path, ["--version"])
            claudeOK = result.ok
            claudeCheck = result.ok
                ? "✓ \(path) — \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
                : "✗ \(path): \(result.failureLine)"
        } catch {
            claudeOK = false
            claudeCheck = "✗ \(error.localizedDescription)"
        }
    }
}
