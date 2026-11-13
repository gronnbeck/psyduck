import SwiftUI

/// One file's diff against the workspace's base commit, in the center pane.
struct DiffView: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    let file: DiffFile

    @State private var lines: [DiffLine] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { store.openDiff[workspace.id] = nil } label: {
                    Label("chat", systemImage: "chevron.left")
                }
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
                Text(file.path).font(.mono(13, .semibold)).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                Spacer()
                if let a = file.additions, let d = file.deletions {
                    Text("+\(a)").font(.mono(11)).foregroundStyle(Ink.leaf)
                    Text("−\(d)").font(.mono(11)).foregroundStyle(Ink.berry)
                }
                Text("vs \(workspace.baseRef)").font(.mono(11)).foregroundStyle(Ink.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            InkRule(vertical: false)

            if let error {
                Text(error).font(.mono(12)).foregroundStyle(Ink.berry).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loaded && lines.isEmpty {
                Text("no textual changes").font(.sans(13)).foregroundStyle(Ink.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    // A two-axis ScrollView centers content smaller than
                    // itself; pin it to the top left instead.
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                DiffLineRow(line: line)
                            }
                        }
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
            }
        }
        .background(Ink.paper)
        // Reload when the file is reselected or its counts change.
        .task(id: "\(file.path)|\(file.additions ?? -1)|\(file.deletions ?? -1)|\(store.changes[workspace.id]?.count ?? 0)") {
            await load()
        }
    }

    private func load() async {
        do {
            let text = try await store.settings.git.diff(of: file, in: workspace.path, base: workspace.baseCommit)
            // git's file headers repeat what the title bar already says.
            lines = Git.parseDiff(text).filter { $0.kind != .header }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .frame(width: 16)
                .foregroundStyle(markerColor)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .header || line.kind == .hunk ? Ink.ink3 : Ink.ink)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .font(.mono(12))
        .padding(.vertical, 1)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(Ink.ink4)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        default: return ""
        }
    }

    private var markerColor: Color {
        line.kind == .added ? Ink.leaf : Ink.berry
    }

    private var background: Color {
        switch line.kind {
        case .added: return Ink.leaf.opacity(0.14)
        case .removed: return Ink.berry.opacity(0.12)
        case .hunk: return Ink.paper2
        default: return .clear
        }
    }
}
