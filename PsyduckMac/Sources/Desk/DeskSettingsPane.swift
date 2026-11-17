import SwiftUI

struct SettingsPane: View {
    @EnvironmentObject private var settings: DeskSettings
    @EnvironmentObject private var prs: PRStore
    @EnvironmentObject private var reviews: ReviewStore
    @EnvironmentObject private var updater: UpdaterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            VStack(alignment: .leading, spacing: 12) {
                heading("source", "which tool desk runs to find your pull requests.")
                HStack(alignment: .top, spacing: 16) {
                    SourceCard(source: .gh, title: "gh cli", detail: "fast. uses your existing gh login.")
                    SourceCard(source: .claude, title: "claude", detail: "asks claude code to do the lookup. slower, more flexible.")
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("runs").microLabel()
                    ForEach(settings.commands, id: \.self) { command in
                        Text("$ " + command)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .font(.mono(12))
                .lineSpacing(3)
                .foregroundStyle(Ink.inkMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.bg300))
            }

            VStack(alignment: .leading, spacing: 12) {
                heading("reviews", "\(settings.agent) reviews in the background, one pull request at a time.")
                Checkbox(on: $settings.autoReview, title: "review new requests automatically",
                         detail: "when someone asks for your review, \(settings.agent) reviews it right away — and again when new commits land.")
                VStack(alignment: .leading, spacing: 8) {
                    Text("reviewer's name").font(.sans(13, .semibold)).foregroundStyle(Ink.ink)
                    InkField(placeholder: "claude", text: $settings.agentName)
                        .frame(maxWidth: 280)
                    Text("what desk calls the reviewer. just a name — it's still claude doing the work.")
                        .font(.sans(12)).foregroundStyle(Ink.inkMuted)
                }
                .padding(.top, 8)
            }

            ReviewAgentsEditor()

            ReviewPromptEditor()

            VStack(alignment: .leading, spacing: 12) {
                heading("tone of voice", "how the comments \(settings.agent) drafts for github should sound. they go out as you, so write it the way you'd brief a colleague.")
                InkEditor(text: $settings.reviewTone,
                          placeholder: "e.g. casual and short. ask questions instead of giving orders. no \"please\" or \"great work!\". british spelling.",
                          minHeight: 80)
                Text("used when drafting and when you ask for changes. empty means \(settings.agent)'s default: direct, kind and specific.")
                    .font(.sans(12)).foregroundStyle(Ink.inkMuted)
            }

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("tool paths").font(.display(20)).foregroundStyle(Ink.ink)
                    HStack(spacing: 4) {
                        Text("where each cli lives. run")
                        Text("which gh").font(.mono(13)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Ink.bg300))
                        Text("if you're not sure.")
                    }
                    .font(.sans(14))
                    .foregroundStyle(Ink.inkMuted)
                }
                ToolPath(tool: "gh", placeholder: "/opt/homebrew/bin/gh", path: $settings.ghPath)
                VStack(alignment: .leading, spacing: 8) {
                    ToolPath(tool: "claude", placeholder: "~/.local/bin/claude", path: $settings.claudePath)
                    Text("used for reviews, and to find pull requests when source is claude.")
                        .font(.sans(12)).foregroundStyle(Ink.inkMuted)
                }
            }

            Text("psyduck \(updater.versionDescription)")
                .font(.mono(11))
                .foregroundStyle(Ink.inkMuted)
        }
        .frame(maxWidth: 640, alignment: .leading)
        .onChange(of: settings.source) { _, _ in
            Task { await prs.refresh() }
        }
        .onChange(of: settings.autoReview) { _, _ in
            reviews.catchUp(prs.lists.review)
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.display(20)).foregroundStyle(Ink.ink)
            Text(detail).font(.sans(14)).foregroundStyle(Ink.inkMuted)
        }
    }
}

/// The four stages a review runs through, the model each runs on, which
/// specialists take part, and how many agents may run at once.
private struct ReviewAgentsEditor: View {
    @EnvironmentObject private var settings: DeskSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("how reviews run").font(.display(20)).foregroundStyle(Ink.ink)
                Text("each review is a team of agents, every one a read-only claude. findings are checked before you see them.")
                    .font(.sans(14)).foregroundStyle(Ink.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ReviewStage.allCases.enumerated()), id: \.element) { index, stage in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)").font(.mono(12, .medium)).foregroundStyle(Ink.inkMuted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stage.label).font(.sans(14, .semibold)).foregroundStyle(Ink.ink)
                                Text(stage.detail).font(.sans(13)).foregroundStyle(Ink.inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack(spacing: 6) {
                            Text("model").font(.mono(11)).foregroundStyle(Ink.inkMuted).frame(width: 44, alignment: .leading)
                            ForEach(ReviewStage.models, id: \.self) { model in
                                Chip(text: model.isEmpty ? "claude's default" : model, on: settings.model(stage) == model) {
                                    settings.stageModels[stage] = model
                                }
                            }
                        }
                        .padding(.leading, 20)
                        if stage == .specialists {
                            specialists.padding(.leading, 20)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Ink.line).frame(height: 1) }
                    }
                }
            }
            .inkBox(12, fill: Ink.bg200)

            VStack(alignment: .leading, spacing: 8) {
                Text("agents at once").font(.sans(13, .semibold)).foregroundStyle(Ink.ink)
                HStack(spacing: 6) {
                    ForEach([1, 2, 4, 8, 0], id: \.self) { n in
                        Chip(text: n == 0 ? "unlimited" : String(n), on: settings.maxAgents == n) { settings.maxAgents = n }
                    }
                }
                Text("across every review, background ones included. the rest wait their turn. a review uses \(2 + settings.specialists.count) or more.")
                    .font(.sans(12)).foregroundStyle(Ink.inkMuted)
            }
            .padding(.top, 8)
        }
    }

    private var specialists: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Specialist.all) { specialist in
                let on = !settings.specialistsOff.contains(specialist.id)
                Button {
                    if on { settings.specialistsOff.insert(specialist.id) } else { settings.specialistsOff.remove(specialist.id) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        CheckMark(on: on, size: 13)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(specialist.name).font(.sans(13, .semibold)).foregroundStyle(Ink.ink)
                            Text(specialist.brief.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
                                .font(.sans(12)).foregroundStyle(Ink.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }
}

private struct Chip: View {
    let text: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.mono(12, .medium))
                .foregroundStyle(on ? Ink.onBrand : Ink.inkMuted)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(on ? Ink.brand : Ink.bg200))
                .overlay { if !on { Capsule().strokeBorder(Ink.lineStrong, lineWidth: 1) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: on)
    }
}

/// The review prompt, edited in place. Placeholders are filled in per pull
/// request; the read-only rules and the answer's shape aren't in here, so
/// no edit can lose them.
private struct ReviewPromptEditor: View {
    @EnvironmentObject private var settings: DeskSettings
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("review prompt").font(.display(20)).foregroundStyle(Ink.ink)
                    Text("what \(settings.agent)'s first pass is asked to do for every review. the read-only rules and the shape of the answer are fixed, so editing this can't let it write to github.")
                        .font(.sans(14)).foregroundStyle(Ink.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                if !settings.reviewPromptIsDefault {
                    Button("reset to default") { settings.reviewPrompt = ReviewStore.defaultReviewPrompt }
                        .buttonStyle(GhostButtonStyle(size: 13, color: Ink.inkMuted))
                        .fixedSize()
                }
            }

            TextEditor(text: $settings.reviewPrompt)
                .font(.mono(12))
                .lineSpacing(3)
                .foregroundStyle(Ink.ink)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(10)
                .frame(height: 380)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.bg000))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.lineStrong, lineWidth: 1))
                .focusRing(focused, radius: 8)
                .animation(.easeOut(duration: 0.08), value: focused)

            VStack(alignment: .leading, spacing: 4) {
                Text("filled in per pull request").microLabel().padding(.bottom, 2)
                ForEach(ReviewStore.placeholders, id: \.0) { name, meaning in
                    HStack(spacing: 10) {
                        Text(name).font(.mono(12, .medium)).foregroundStyle(Ink.ink).frame(width: 84, alignment: .leading)
                        Text(meaning).font(.sans(12)).foregroundStyle(Ink.inkMuted)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.bg200))
        }
    }
}

private struct Checkbox: View {
    @Binding var on: Bool
    let title: String
    let detail: String

    var body: some View {
        Button { on.toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                CheckMark(on: on, size: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.sans(14, .semibold)).foregroundStyle(Ink.ink)
                    Text(detail).font(.sans(13)).foregroundStyle(Ink.inkMuted).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .inkBox(12, fill: Ink.bg200)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SourceCard: View {
    @EnvironmentObject private var settings: DeskSettings
    let source: PRSource
    let title: String
    let detail: String

    var body: some View {
        let on = settings.source == source
        Button { settings.source = source } label: {
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(on ? Ink.brand : Ink.bg200)
                    .overlay { if !on { Circle().strokeBorder(Ink.lineStrong, lineWidth: 1) } }
                    .overlay { if on { Circle().fill(Ink.onBrand).frame(width: 6, height: 6) } }
                    .frame(width: 16, height: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.sans(14, .semibold)).foregroundStyle(Ink.ink)
                    Text(detail).font(.sans(13)).foregroundStyle(Ink.inkMuted).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .inkBox(12, fill: on ? Ink.bg300 : Ink.bg200, border: on ? Ink.brand : Ink.line)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: on)
    }
}

private struct ToolPath: View {
    @EnvironmentObject private var settings: DeskSettings
    let tool: String
    let placeholder: String
    @Binding var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tool).font(.sans(13, .semibold)).foregroundStyle(Ink.ink)
            HStack(spacing: 8) {
                InkField(placeholder: placeholder, text: $path, mono: true)
                Button("detect") { Task { await settings.detect(tool) } }
                    .buttonStyle(GhostButtonStyle())
                Button("test") { Task { await settings.test(tool) } }
                    .buttonStyle(HardButtonStyle(kind: .outlined))
                    .disabled(settings.testing.contains(tool))
            }
            if settings.testing.contains(tool) {
                output { Dots(text: "testing").foregroundStyle(Ink.inkMuted) }
            } else if let lines = settings.output[tool] {
                output {
                    ForEach(lines) { line in
                        Text(line.text).foregroundStyle(color(line.tone)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func output<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) { content() }
            .font(.mono(12))
            .lineSpacing(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.bg200))
    }

    private func color(_ tone: OutputLine.Tone) -> Color {
        switch tone {
        case .ok: return Ink.success
        case .bad: return Ink.danger
        case .dim: return Ink.inkMuted
        }
    }
}
