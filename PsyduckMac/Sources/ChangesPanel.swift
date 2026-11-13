import SwiftUI

/// The right-hand panel: every file the workspace has changed since it was
/// cut from its base. Clicking one opens its diff in the center pane.
struct ChangesPanel: View {
    @EnvironmentObject private var store: AppStore
    let workspace: Workspace

    private var files: [DiffFile] { store.changes[workspace.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("changes").microLabel()
                Text("\(files.count)").font(.mono(11, .medium)).foregroundStyle(Ink.ink3)
                Spacer()
                let added = files.compactMap(\.additions).reduce(0, +)
                let removed = files.compactMap(\.deletions).reduce(0, +)
                if added + removed > 0 {
                    Text("+\(added)").font(.mono(11)).foregroundStyle(Ink.leaf)
                    Text("−\(removed)").font(.mono(11)).foregroundStyle(Ink.berry)
                }
                Button { Task { await store.refreshChanges(workspace.id) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GhostButtonStyle())
                .help("refresh")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            InkRule(vertical: false)

            if files.isEmpty {
                VStack(spacing: 6) {
                    Text("no changes yet").font(.sans(13)).foregroundStyle(Ink.ink3)
                    Text("against \(workspace.baseRef)").font(.mono(11)).foregroundStyle(Ink.ink4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(files) { file in
                            FileRow(file: file, selected: store.openDiff[workspace.id]?.path == file.path) {
                                store.openDiff[workspace.id] = file
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Ink.paper2)
        .task(id: workspace.id) {
            // Catches edits made outside psyduck too, while the workspace is open.
            while !Task.isCancelled {
                await store.refreshChanges(workspace.id)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

private struct FileRow: View {
    let file: DiffFile
    let selected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(file.status == .untracked ? "A" : file.status.rawValue)
                    .font(.mono(10, .bold))
                    .foregroundStyle(file.status.color)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.fileName).font(.mono(12, selected ? .semibold : .regular)).lineLimit(1)
                    if !file.directory.isEmpty {
                        Text(file.directory).font(.mono(10)).foregroundStyle(Ink.ink3)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if let a = file.additions, let d = file.deletions {
                    Text("+\(a)").font(.mono(10)).foregroundStyle(Ink.leaf)
                    Text("−\(d)").font(.mono(10)).foregroundStyle(Ink.berry)
                } else if file.status == .untracked {
                    Text("new").font(.mono(10)).foregroundStyle(Ink.leaf)
                } else {
                    Text("bin").font(.mono(10)).foregroundStyle(Ink.ink3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Ink.paper : .clear))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.ink, lineWidth: Ink.border)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
