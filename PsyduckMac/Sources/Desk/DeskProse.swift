import Foundation

/// A run of text that is either prose or `code`.
struct Segment: Hashable {
    let text: String
    let isCode: Bool
}

/// A run of inline text with its styling: what `**bold**`, `*italic*`,
/// `` `code` `` and `[links](…)` come to.
struct Span: Hashable {
    var text = ""
    var code = false
    var bold = false
    var italic = false
    var strike = false
    var link: URL?
}

/// A PR description as blocks: paragraphs, headings, list items, code,
/// tables and quotes — plus `<details>` sections, which GitHub shows
/// collapsed and so does desk. Text is kept as inline markdown; `spans`
/// reads it.
struct ProseBlock: Hashable {
    enum Kind { case paragraph, heading, item, details, code, table, quote }
    let kind: Kind
    /// The text; the summary line for `.details`; the code for `.code`.
    let text: String
    /// What a `.details` section opens to, or what a `.quote` holds.
    var children: [ProseBlock] = []
    /// A heading's level (1–6), or how deep a list item is nested (from 0).
    var level = 0
    /// A list item's marker: `1.` for a numbered one, `[ ]` or `[x]` for a
    /// task. Nil is a bullet.
    var marker: String?
    /// A table's rows, the header first.
    var rows: [[String]] = []
}

enum DeskProse {
    /// Splits on single backticks: odd runs are code.
    static func segments(_ text: String) -> [Segment] {
        text.components(separatedBy: "`").enumerated().compactMap { index, part in
            part.isEmpty ? nil : Segment(text: part, isCode: index % 2 == 1)
        }
    }

    /// The text with its inline markdown read away.
    static func plain(_ text: String) -> String {
        spans(text).map(\.text).joined()
    }

    /// Reads a description written in markdown, HTML, or — like Dependabot's —
    /// both at once.
    static func blocks(_ body: String) -> [ProseBlock] {
        // GitHub sends descriptions with \r\n line endings.
        var text = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        // Code blocks come out first, so nothing below reads them as markup.
        var fences: [String] = []
        let pre = try! NSRegularExpression(pattern: #"<pre[^>]*>([\s\S]*?)</pre>"#, options: [.caseInsensitive])
        while let match = pre.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) {
            let code = text[inner].replacingOccurrences(of: #"</?code[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            fences.append(inline(code, keepNewlines: true).trimmingCharacters(in: .newlines))
            text.replaceSubrange(whole, with: "\n\u{2}\(fences.count - 1)\n")
        }
        let fence = try! NSRegularExpression(pattern: #"^[ \t]*(```|~~~)[^\n]*\n(?:([\s\S]*?)\n)??[ \t]*\1[ \t]*$"#, options: [.anchorsMatchLines])
        while let match = fence.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let whole = Range(match.range, in: text) {
            fences.append(Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? "")
            text.replaceSubrange(whole, with: "\n\u{2}\(fences.count - 1)\n")
        }
        return blocks(text, fences: fences)
    }

    private static func blocks(_ body: String, fences: [String]) -> [ProseBlock] {
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
                summary = plain(inline(String(content[found])))
                content.removeSubrange(found)
            }
            text.replaceSubrange(whole, with: "\n\n\u{1}\(sections.count)\n\n")
            sections.append(ProseBlock(kind: .details, text: summary.isEmpty ? "details" : summary, children: blocks(content, fences: fences)))
        }

        return markdownBlocks(htmlToMarkdown(text), fences: fences).map { block in
            if block.kind == .paragraph, block.text.hasPrefix("\u{1}"), let i = Int(block.text.dropFirst()), sections.indices.contains(i) {
                return sections[i]
            }
            return block
        }
    }

    // MARK: Markdown

    private static func markdownBlocks(_ text: String, fences: [String]) -> [ProseBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [ProseBlock] = []
        var paragraph: [String] = []
        /// Indents of the list items the current one is nested in.
        var indents: [Int] = []
        var afterBlank = true

        func flush() {
            if !paragraph.isEmpty {
                // A line break in a description is a line break on GitHub too.
                blocks.append(ProseBlock(kind: .paragraph, text: paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            index += 1
            defer { afterBlank = line.isEmpty }

            // Rules, and link definitions — which is also how `[//]: # (…)`
            // comments are written — show nothing on GitHub either.
            if line.isEmpty
                || line.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil
                || line.range(of: #"^\[[^\]]*\]:\s"#, options: .regularExpression) != nil {
                flush()
            } else if line.hasPrefix("\u{1}") {
                flush()
                indents = []
                blocks.append(ProseBlock(kind: .paragraph, text: line))
            } else if line.hasPrefix("\u{2}"), let i = Int(line.dropFirst()), fences.indices.contains(i) {
                flush()
                blocks.append(ProseBlock(kind: .code, text: fences[i]))
            } else if line.hasPrefix(">") {
                flush()
                indents = []
                var quoted = [line]
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let inner = quoted.map { String($0.dropFirst()) }.joined(separator: "\n")
                let children = markdownBlocks(inner, fences: fences)
                if !children.isEmpty { blocks.append(ProseBlock(kind: .quote, text: "", children: children)) }
            } else if line.contains("|"), index < lines.count, isTableRule(lines[index]) {
                flush()
                indents = []
                var rows = [cells(line)]
                index += 1
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                blocks.append(ProseBlock(kind: .table, text: "", rows: table(rows)))
            } else if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                indents = []
                let title = line[match.upperBound...].replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
                blocks.append(ProseBlock(kind: .heading, text: clean(title), level: line.prefix { $0 == "#" }.count))
            } else if let (marker, item) = listItem(line) {
                flush()
                while let last = indents.last, last > indent { indents.removeLast() }
                if indents.last != indent { indents.append(indent) }
                blocks.append(ProseBlock(kind: .item, text: clean(item), level: indents.count - 1, marker: marker))
            } else if paragraph.isEmpty, let last = blocks.last, last.kind == .item, !afterBlank || indent >= 2 {
                // A wrapped list item continues the one above it.
                blocks[blocks.count - 1] = ProseBlock(kind: .item, text: last.text + "\n" + clean(line), level: last.level, marker: last.marker)
            } else {
                if paragraph.isEmpty { indents = [] }
                paragraph.append(clean(line))
            }
        }
        flush()
        return blocks.filter { block in
            switch block.kind {
            case .paragraph, .heading, .item: return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .table: return !block.rows.isEmpty
            case .details, .code, .quote: return true
            }
        }
    }

    /// The marker (nil for a bullet) and the text of a list item.
    private static func listItem(_ line: String) -> (String?, String)? {
        for (prefix, marker) in [("- [ ] ", "[ ]"), ("- [x] ", "[x]"), ("- [X] ", "[x]"), ("* [ ] ", "[ ]"), ("* [x] ", "[x]")] where line.hasPrefix(prefix) {
            return (marker, String(line.dropFirst(prefix.count)))
        }
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return (nil, String(line.dropFirst(prefix.count)))
        }
        if let match = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
            return (line[match].filter(\.isNumber) + ".", String(line[match.upperBound...]))
        }
        return nil
    }

    /// The `|---|:--:|` line under a table's header.
    private static func isTableRule(_ line: String) -> Bool {
        line.contains("|") && line.contains("-")
            && line.range(of: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#, options: .regularExpression) != nil
    }

    /// One table line as cells. A `|` inside code or after a backslash is text.
    private static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|", !inCode {
                cells.append(cell)
                cell = ""
            } else {
                if character == "`" { inCode.toggle() }
                cell.append(character)
            }
        }
        cells.append(cell)
        // The pipes at either end of a line don't open a cell.
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, line.trimmingCharacters(in: .whitespaces).hasSuffix("|") { cells.removeLast() }
        return cells.map(clean)
    }

    /// Every row as wide as the widest, without the columns nobody filled in.
    private static func table(_ rows: [[String]]) -> [[String]] {
        let width = rows.map(\.count).max() ?? 0
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        let used = (0..<width).filter { column in padded.contains { !$0[column].isEmpty } }
        return padded.map { row in used.map { row[$0] } }
    }

    /// Images show nothing here. Everything else inline is left for `spans`.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            // A link whose text was only an image, like Dependabot's badge.
            .replacingOccurrences(of: #"\[\s*\]\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Inline

    /// Inline markdown as styled runs: code, bold, italic, strikethrough,
    /// links, and bare URLs.
    static func spans(_ text: String) -> [Span] {
        var out: [Span] = []
        read(Array(text), Span(), into: &out)
        return out
    }

    private static func read(_ c: [Character], _ style: Span, into out: inout [Span]) {
        var buffer = ""
        func flush(_ out: inout [Span]) {
            guard !buffer.isEmpty else { return }
            var span = style
            span.text = buffer
            out.append(span)
            buffer = ""
        }

        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                buffer.append(c[i + 1])
                i += 2
            } else if ch == "`" {
                let n = run(c, i)
                if let close = (i + n..<c.count).first(where: { c[$0] == "`" && ($0 == 0 || c[$0 - 1] != "`") && run(c, $0) == n }) {
                    flush(&out)
                    var span = style
                    span.code = true
                    span.text = String(c[i + n..<close]).trimmingCharacters(in: .whitespaces)
                    out.append(span)
                    i = close + n
                } else {
                    buffer.append(String(repeating: "`", count: n))
                    i += n
                }
            } else if ch == "[", let (label, url, end) = link(c, i) {
                flush(&out)
                var inner = style
                inner.link = url
                read(label, inner, into: &out)
                i = end
            } else if ch == "h", style.link == nil, i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber), let (url, end) = bareURL(c, i) {
                flush(&out)
                var span = style
                span.link = url
                span.text = String(c[i..<end])
                out.append(span)
                i = end
            } else if ch == "*" || ch == "_" || ch == "~" {
                let n = run(c, i)
                let length = ch == "~" ? 2 : min(n, 3)
                if n >= length, let close = closing(c, ch, length, from: i) {
                    flush(&out)
                    var inner = style
                    if ch == "~" { inner.strike = true }
                    else {
                        if length >= 2 { inner.bold = true }
                        if length != 2 { inner.italic = true }
                    }
                    read(Array(c[i + length..<close]), inner, into: &out)
                    i = close + length
                } else {
                    buffer.append(String(repeating: ch, count: n))
                    i += n
                }
            } else {
                buffer.append(ch)
                i += 1
            }
        }
        flush(&out)
    }

    /// How many times the character at `i` repeats from there.
    private static func run(_ c: [Character], _ i: Int) -> Int {
        var n = 0
        while i + n < c.count, c[i + n] == c[i] { n += 1 }
        return n
    }

    /// Where the emphasis opened at `i` closes, if it is emphasis at all:
    /// `2 * 3` and `snake_case` are not.
    private static func closing(_ c: [Character], _ mark: Character, _ length: Int, from i: Int) -> Int? {
        let start = i + length
        guard start < c.count, !c[start].isWhitespace else { return nil }
        if mark == "_", i > 0, c[i - 1].isLetter || c[i - 1].isNumber { return nil }
        var j = start + 1
        while j + length <= c.count {
            if c[j] == "`" {
                // Skip a code span; its contents aren't markup.
                j = (c[(j + 1)...].firstIndex(of: "`") ?? j) + 1
                continue
            }
            if c[j] == mark, run(c, j) == length, !c[j - 1].isWhitespace, c[j - 1] != mark {
                let after = j + length
                if mark != "_" || after >= c.count || !(c[after].isLetter || c[after].isNumber) { return j }
            }
            j += c[j] == mark ? run(c, j) : 1
        }
        return nil
    }

    /// `[label](url)` at `i`: the label, where it goes, and where it ends.
    private static func link(_ c: [Character], _ i: Int) -> ([Character], URL, Int)? {
        var depth = 0
        var j = i
        while j < c.count {
            if c[j] == "[" { depth += 1 }
            if c[j] == "]" { depth -= 1; if depth == 0 { break } }
            j += 1
        }
        guard j + 1 < c.count, c[j + 1] == "(", let end = c[(j + 2)...].firstIndex(of: ")") else { return nil }
        // A title after the address, `(url "title")`, isn't part of it.
        let target = String(c[j + 2..<end]).split(separator: " ").first.map(String.init) ?? ""
        guard j > i + 1, let url = URL(string: target), url.scheme != nil else { return nil }
        return (Array(c[i + 1..<j]), url, end + 1)
    }

    /// A URL written out in the text.
    private static func bareURL(_ c: [Character], _ i: Int) -> (URL, Int)? {
        guard String(c[i..<min(i + 8, c.count)]).range(of: #"^https?://"#, options: .regularExpression) != nil else { return nil }
        var end = i
        while end < c.count, !c[end].isWhitespace, c[end] != "<", c[end] != "`" { end += 1 }
        // The full stop after a URL ends the sentence, not the address.
        while end > i, ".,;:!?\"'*_".contains(c[end - 1]) || (c[end - 1] == ")" && !c[i..<end].contains("(")) { end -= 1 }
        guard let url = URL(string: String(c[i..<end])), url.host != nil else { return nil }
        return (url, end)
    }

    // MARK: HTML

    /// Turns the block-level HTML a description might contain into the
    /// markdown the parser above already reads.
    static func htmlToMarkdown(_ html: String) -> String {
        var text = htmlTables(html)
        let rules: [(String, String)] = [
            (#"<h[1-6][^>]*>([\s\S]*?)</h[1-6]>"#, "\n\n### $1\n\n"),
            (#"<li[^>]*>"#, "\n- "),
            (#"</li>"#, "\n"),
            (#"<br\s*/?>"#, "\n"),
            (#"</?(p|ul|ol|blockquote|div|table|thead|tbody|tr|hr)[^>]*>"#, "\n\n"),
            (#"</t[dh]>"#, " "),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        return inline(text, keepNewlines: true)
    }

    /// An HTML table, rewritten as the markdown one the parser reads.
    private static func htmlTables(_ html: String) -> String {
        func captures(_ pattern: String, in text: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        var text = html
        let table = try! NSRegularExpression(pattern: #"<table[^>]*>([\s\S]*?)</table>"#, options: [.caseInsensitive])
        while let match = table.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) {
            let rows = captures(#"<tr[^>]*>([\s\S]*?)</tr>"#, in: String(text[inner])).map { row in
                captures(#"<t[dh][^>]*>([\s\S]*?)</t[dh]>"#, in: row).map { inline($0).replacingOccurrences(of: "|", with: "\\|") }
            }.filter { !$0.isEmpty }
            var lines = rows.map { "| " + $0.joined(separator: " | ") + " |" }
            if let head = rows.first { lines.insert("|" + String(repeating: "---|", count: head.count), at: 1) }
            text.replaceSubrange(whole, with: "\n\n" + lines.joined(separator: "\n") + "\n\n")
        }
        return text
    }

    /// Inline HTML: `<code>` becomes backticks, links and emphasis become
    /// their markdown, every other tag goes, entities are decoded.
    static func inline(_ html: String, keepNewlines: Bool = false) -> String {
        let coded = html
            .replacingOccurrences(of: #"<a\s[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>"#, with: "[$2]($1)", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</?(strong|b)>"#, with: "**", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</?(em|i)>"#, with: "*", options: [.regularExpression, .caseInsensitive])
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
