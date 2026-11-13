import SwiftUI

/// Settings, as a page inside the main window (not a separate window). It
/// takes over the chat and changes panes; the sidebar stays.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updater: UpdaterModel
    @EnvironmentObject private var store: AppStore

    @State private var claudeCheck: String?
    @State private var claudeOK = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { store.showingSettings = false } label: {
                    Label("back", systemImage: "chevron.left")
                }
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
                Text("settings").font(.sans(16, .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            InkRule(vertical: false)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    section("claude") {
                        row("path to claude", hint: "the claude code cli psyduck runs in each worktree") {
                            HStack(spacing: 8) {
                                field($settings.claudePath, placeholder: "~/.local/bin/claude")
                                Button("detect") {
                                    Task {
                                        if let found = await Shell.detect("claude") { settings.claudePath = found }
                                        await check()
                                    }
                                }
                                .buttonStyle(InkButtonStyle(fill: Ink.paper, small: true))
                                Button("check") { Task { await check() } }
                                    .buttonStyle(InkButtonStyle(fill: Ink.paper, small: true))
                            }
                        }
                        if let claudeCheck {
                            Text(claudeCheck)
                                .font(.mono(11))
                                .foregroundStyle(claudeOK ? Ink.leaf : Ink.berry)
                                .textSelection(.enabled)
                        }
                        row("permissions", hint: "what claude may do without asking. the worktree keeps edits off your checkout, but it isn't a sandbox.") {
                            Picker("", selection: $settings.permissionMode) {
                                ForEach(AppSettings.permissionModes, id: \.id) { mode in
                                    Text(mode.label).tag(mode.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                            .font(.sans(13))
                        }
                        row("model", hint: "an alias like opus or sonnet, or a full model name. empty uses claude's default.") {
                            field($settings.model, placeholder: "claude's default")
                        }
                    }

                    section("git") {
                        row("path to git", hint: nil) {
                            field($settings.gitPath, placeholder: "/usr/bin/git")
                        }
                        row("worktrees go in", hint: "each workspace is <here>/<repo>/<name>") {
                            field($settings.workspacesRoot, placeholder: AppSettings.defaultWorkspacesRoot)
                        }
                        row("cloned repos go in", hint: nil) {
                            field($settings.reposRoot, placeholder: AppSettings.defaultReposRoot)
                        }
                    }

                    section("about") {
                        HStack {
                            Text(updater.versionDescription).font(.mono(12)).foregroundStyle(Ink.ink2)
                            Spacer()
                            Button("check for updates →") { updater.checkForUpdates() }
                                .buttonStyle(InkButtonStyle(fill: Ink.paper, small: true))
                                .disabled(!updater.canCheckForUpdates)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Ink.paper)
        .task { await check() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).microLabel()
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkBox(10, fill: Ink.paper2)
        }
    }

    private func row<Content: View>(_ label: String, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.sans(13, .semibold))
            if let hint {
                Text(hint).font(.sans(12)).foregroundStyle(Ink.ink3)
            }
            content()
        }
    }

    private func field(_ text: Binding<String>, placeholder: String) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Ink.ink4))
            .textFieldStyle(.plain)
            .font(.mono(12))
            .foregroundStyle(Ink.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .inkBox(6, fill: Ink.paper)
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
