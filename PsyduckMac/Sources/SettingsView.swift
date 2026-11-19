import PsyduckCore
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

                    section("Remote hosts") {
                        Text("Other machines that run agents for you. Each one runs `psyduck serve`; this app reaches it by running the command below and talking over it, usually ssh. Its workspaces show in the sidebar under its name, and keep working when this Mac is asleep. A host uses its own claude and git logins and its own settings file, not the ones on this page.")
                            .font(.sans(12)).foregroundStyle(Tk.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(settings.hosts) { host in
                            HostRow(host: host) { hostStatus(host) }
                        }
                        Button("Add a host") { settings.hosts.append(RemoteHost(name: "", command: "")) }
                            .buttonStyle(.tkSecondary)
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

    @ViewBuilder
    private func hostStatus(_ host: RemoteHost) -> some View {
        switch store.hostStatus[host.id] {
        case .connected(let machine):
            Text(machine.isEmpty ? "✓ connected" : "✓ connected to \(machine)")
                .font(.mono(12)).foregroundStyle(Tk.success)
        case .connecting:
            Text("connecting…").font(.mono(12)).foregroundStyle(Tk.inkMuted)
        case .offline(let reason):
            Text("✗ \(reason)").font(.mono(12)).foregroundStyle(Tk.danger)
                .lineLimit(2).textSelection(.enabled)
        case nil:
            EmptyView()
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

/// One remote host in settings. The command is only run once it's saved,
/// never while it's half typed.
private struct HostRow<Status: View>: View {
    @EnvironmentObject private var settings: AppSettings
    let host: RemoteHost
    @ViewBuilder var status: Status
    @State private var name = ""
    @State private var command = ""

    private var changed: Bool { name != host.name || command != host.command }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TkTextField(text: $name, placeholder: "Name, like studio")
                    .frame(width: 180)
                    .onSubmit(save)
                if !changed { status }
                Spacer()
                if changed {
                    Button(host.command.isEmpty ? "Connect" : "Save", action: save)
                        .buttonStyle(.tkPrimary)
                        .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Remove") { settings.hosts.removeAll { $0.id == host.id } }
                    .buttonStyle(.tkGhost)
            }
            TkTextField(text: $command, placeholder: "ssh studio docker exec -i psyduck psyduck attach")
                .onSubmit(save)
        }
        .onAppear {
            name = host.name
            command = host.command
        }
    }

    private func save() {
        guard let index = settings.hosts.firstIndex(where: { $0.id == host.id }) else { return }
        settings.hosts[index].name = name.trimmingCharacters(in: .whitespaces)
        settings.hosts[index].command = command.trimmingCharacters(in: .whitespaces)
    }
}
