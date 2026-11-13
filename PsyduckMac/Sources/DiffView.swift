import SwiftUI

/// One file's diff, opened wide in the center pane.
struct DiffView: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace
    let file: DiffFile

    @State private var lines: [DiffLine] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(leading: 12, trailing: 16) {
                Button { store.openDiff[workspace.id] = nil } label: {
                    Label("Session", systemImage: "chevron.left")
                }
                .buttonStyle(.tkGhost)
                .keyboardShortcut(.escape, modifiers: [])
                Text(file.path).font(.mono(13, .medium)).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                Spacer()
                if let a = file.additions, let d = file.deletions {
                    Text("+\(a)").font(.mono(12)).foregroundStyle(Tk.success)
                    Text("−\(d)").font(.mono(12)).foregroundStyle(Tk.danger)
                }
                Text("vs \(workspace.baseRef)").font(.mono(12)).foregroundStyle(Tk.inkFaint)
            }

            if let error {
                Text(error).font(.mono(12)).foregroundStyle(Tk.danger).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loaded && lines.isEmpty {
                Text("No textual changes").font(.sans(13)).foregroundStyle(Tk.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    // A two-axis ScrollView centers content smaller than
                    // itself; pin it to the top left instead.
                    ScrollView([.vertical, .horizontal]) {
                        DiffLines(lines: lines)
                            .padding(.vertical, 8)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
            }
        }
        .background(Tk.bg000)
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

/// Diff lines, Tinker style: tinted rows, coloured line numbers.
struct DiffLines: View {
    let lines: [DiffLine]
    /// The panel's narrow card: one number column instead of two.
    var compact = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                row(line)
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            if compact {
                number(line.newNumber ?? line.oldNumber, color: numberColor(line))
            } else {
                number(line.oldNumber, color: numberColor(line))
                number(line.newNumber, color: numberColor(line))
            }
            Text(marker(line))
                .frame(width: 14, alignment: .leading)
                .foregroundStyle(line.kind == .added ? Tk.success : Tk.danger)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk ? Tk.inkFaint : Tk.ink)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
        }
        .font(.mono(12))
        .frame(height: 20)
        .background(background(line))
    }

    private func number(_ value: Int?, color: Color) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(color)
            .frame(width: 32, alignment: .trailing)
            .padding(.trailing, 8)
    }

    private func numberColor(_ line: DiffLine) -> Color {
        switch line.kind {
        case .added: return Tk.success
        case .removed: return Tk.danger
        default: return Tk.inkFaint
        }
    }

    private func marker(_ line: DiffLine) -> String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        default: return ""
        }
    }

    private func background(_ line: DiffLine) -> Color {
        switch line.kind {
        case .added: return Tk.success.opacity(0.14)
        case .removed: return Tk.danger.opacity(0.14)
        case .hunk: return Tk.bg100
        default: return .clear
        }
    }
}
