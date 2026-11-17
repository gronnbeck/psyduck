import Foundation

/// A run of text that is either prose or `code`.
struct Segment: Hashable {
    let text: String
    let isCode: Bool
}

/// A PR description, reduced to what the design shows: paragraphs, small
/// headings and list items — plus `<details>` sections, which GitHub shows
/// collapsed and so does desk.
struct ProseBlock: Hashable {
    enum Kind { case paragraph, heading, item, details }
    let kind: Kind
    /// The summary line, for `.details`.
    let text: String
    /// What a `.details` section opens to.
    var children: [ProseBlock] = []
}

enum DeskProse {
    /// Splits on single backticks: odd runs are code.
    static func segments(_ text: String) -> [Segment] {
        text.components(separatedBy: "`").enumerated().compactMap { index, part in
            part.isEmpty ? nil : Segment(text: part, isCode: index % 2 == 1)
        }
    }

    /// Reads a description written in markdown, HTML, or — like Dependabot's —
    /// both at once.
    static func blocks(_ body: String) -> [ProseBlock] {
        // PR templates leave HTML comments behind; nobody wrote those for a reader.
        var text = body.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)

        // Pull each <details> out first and stand a marker line in its place,
        // so its contents become children instead of flooding the description.
        var sections: [ProseBlock] = []
        let pattern = try! NSRegularExpression(pattern: #"<details[^>]*>([\s\S]*?)</details>"#, options: [.caseInsensitive])
        while let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) {
            var content = String(text[inner])
            var summary = "details"
            if let found = content.range(of: #"<summary[^>]*>[\s\S]*?</summary>"#, options: [.regularExpression, .caseInsensitive]) {
                summary = inline(String(content[found]))
                content.removeSubrange(found)
            }
            text.replaceSubrange(whole, with: "\n\n\u{1}\(sections.count)\n\n")
            sections.append(ProseBlock(kind: .details, text: summary.isEmpty ? "details" : summary, children: blocks(content)))
        }

        return markdownBlocks(htmlToMarkdown(text)).map { block in
            if block.kind == .paragraph, block.text.hasPrefix("\u{1}"), let i = Int(block.text.dropFirst()), sections.indices.contains(i) {
                return sections[i]
            }
            return block
        }
    }

    // MARK: Markdown

    private static func markdownBlocks(_ text: String) -> [ProseBlock] {
        var blocks: [ProseBlock] = []
        var paragraph: [String] = []
        var inFence = false

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(ProseBlock(kind: .paragraph, text: paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush()
                inFence.toggle()
                continue
            }
            if inFence {
                // Code blocks keep their lines, shown as code.
                if !line.isEmpty { blocks.append(ProseBlock(kind: .paragraph, text: "`\(raw)`")) }
                continue
            }
            // Quotes read as plain prose here.
            while line.hasPrefix(">") { line = line.dropFirst().trimmingCharacters(in: .whitespaces) }

            // Rules, and link definitions — which is also how `[//]: # (…)`
            // comments are written — show nothing on GitHub either.
            if line.isEmpty
                || line.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil
                || line.range(of: #"^\[[^\]]*\]:\s"#, options: .regularExpression) != nil {
                flush()
            } else if line.hasPrefix("\u{1}") {
                flush()
                blocks.append(ProseBlock(kind: .paragraph, text: line))
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(ProseBlock(kind: .heading, text: clean(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))))
            } else if let item = listItem(line) {
                flush()
                blocks.append(ProseBlock(kind: .item, text: clean(item)))
            } else if paragraph.isEmpty, case .item? = blocks.last?.kind, raw.hasPrefix("  ") {
                // A wrapped list item continues the one above it.
                let last = blocks.removeLast()
                blocks.append(ProseBlock(kind: .item, text: last.text + " " + clean(line)))
            } else {
                paragraph.append(clean(line))
            }
        }
        flush()
        return blocks.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func listItem(_ line: String) -> String? {
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        if let match = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
            return String(line[match.upperBound...])
        }
        return nil
    }

    /// `**bold**`, links and images read fine as plain text, or not at all.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            // A link whose text was only an image, like Dependabot's badge.
            .replacingOccurrences(of: #"\[\s*\]\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: HTML

    /// Turns the block-level HTML a description might contain into the
    /// markdown the parser above already reads.
    static func htmlToMarkdown(_ html: String) -> String {
        var text = html
        let rules: [(String, String)] = [
            (#"<h[1-6][^>]*>([\s\S]*?)</h[1-6]>"#, "\n\n### $1\n\n"),
            (#"<li[^>]*>"#, "\n- "),
            (#"</li>"#, "\n"),
            (#"<br\s*/?>"#, "\n"),
            (#"<pre[^>]*>([\s\S]*?)</pre>"#, "\n```\n$1\n```\n"),
            (#"</?(p|ul|ol|blockquote|div|table|thead|tbody|tr|hr)[^>]*>"#, "\n\n"),
            (#"</t[dh]>"#, " "),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        return inline(text, keepNewlines: true)
    }

    /// Inline HTML: `<code>` becomes backticks, every other tag goes, entities
    /// are decoded.
    static func inline(_ html: String, keepNewlines: Bool = false) -> String {
        let coded = html
            .replacingOccurrences(of: #"<code[^>]*>([^<`]*)</code>"#, with: "`$1`", options: [.regularExpression, .caseInsensitive])
        // Tags go everywhere except inside code spans, where `<name>` is text.
        var text = coded.components(separatedBy: "`").enumerated().map { index, part in
            index % 2 == 1 ? part : part
                .replacingOccurrences(of: #"<img[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"</?[a-zA-Z][^>]*>"#, with: "", options: .regularExpression)
        }.joined(separator: "`")
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        if !keepNewlines {
            text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
        return text.trimmingCharacters(in: keepNewlines ? .whitespaces : .whitespacesAndNewlines)
    }
}
