#if !canImport(Darwin)
import Foundation

// Linux Foundation has no markdown parser, so this is a CommonMark + GFM-table subset that feeds the same
// layout the Darwin walker builds from Foundation's runs, quirks included (see `HudMarkdown.Walker`).
extension HudMarkdown {
    static func portableLines(_ text: String) -> [Line] {
        let source = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var definitions: [String: String] = [:]
        let blocks = MarkdownDefinitions.extracting(MarkdownBlockParser.parse(source.components(separatedBy: "\n")),
                                                    into: &definitions)
        var renderer = MarkdownRenderer(definitions: definitions)
        renderer.render(blocks, in: [])
        return renderer.out
    }
}

private indirect enum MarkdownBlock {
    case paragraph(String)
    case heading(String)
    case code([String])
    case rule
    case html([String])
    case table(header: [String], rows: [[String]])
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
}

// MARK: - line classification

private struct ListMarker {
    let ordered: Bool
    let delimiter: Character
    let number: Int
    /// width is the content column: continuation lines indented this far belong to the item.
    let width: Int
    let content: String

    func continues(_ first: ListMarker) -> Bool { ordered == first.ordered && delimiter == first.delimiter }
}

private struct Fence {
    let char: Character
    let count: Int
    let indent: Int
}

private enum HtmlEnd {
    case marker([String])
    case blankLine
}

private enum MarkdownLine {
    static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd",
        "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset",
        "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu",
        "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul"
    ]
    static let rawTags = ["script", "pre", "style", "textarea"]

    static func isSpace(_ char: Character) -> Bool { char == " " || char == "\t" }

    static func isBlank(_ line: String) -> Bool { line.allSatisfy(isSpace) }

    static func trimmedLeading(_ line: String) -> String { String(line.drop(while: isSpace)) }

    static func trimmed(_ line: String) -> String {
        String(line.drop(while: isSpace).reversed().drop(while: isSpace).reversed())
    }

    /// indent counts leading whitespace columns, a tab advancing to the next multiple of four.
    static func indent(_ line: String) -> Int {
        var column = 0
        for char in line {
            guard isSpace(char) else { break }
            column += char == " " ? 1 : 4 - column % 4
        }
        return column
    }

    /// stripped removes up to `columns` of leading whitespace; a tab it splits leaves its remaining columns as spaces.
    static func stripped(_ line: String, columns: Int) -> String {
        var column = 0
        var index = line.startIndex
        while index < line.endIndex, column < columns, isSpace(line[index]) {
            let next = line[index] == " " ? column + 1 : column + 4 - column % 4
            index = line.index(after: index)
            if next > columns { return String(repeating: " ", count: next - columns) + line[index...] }
            column = next
        }
        return String(line[index...])
    }

    static func isThematicBreak(_ line: String) -> Bool {
        guard indent(line) < 4 else { return false }
        let marks = line.filter { !isSpace($0) }
        guard let first = marks.first, "-*_".contains(first), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == first }
    }

    static func atxHeading(_ line: String) -> String? {
        guard indent(line) < 4 else { return nil }
        let text = trimmedLeading(line)
        let hashes = text.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = text.dropFirst(hashes)
        guard rest.first.map(isSpace) ?? true else { return nil }
        let content = trimmed(String(rest))
        let open = String(content.reversed().drop { $0 == "#" }.reversed())
        if open.isEmpty { return "" }
        return open.last.map(isSpace) == true ? trimmed(open) : content
    }

    static func isSetextUnderline(_ line: String) -> Bool {
        guard indent(line) < 4 else { return false }
        let text = trimmed(line)
        guard let first = text.first, first == "=" || first == "-" else { return false }
        return text.allSatisfy { $0 == first }
    }

    static func fenceOpen(_ line: String) -> Fence? {
        let depth = indent(line)
        let text = trimmedLeading(line)
        guard depth < 4, let char = text.first, char == "`" || char == "~" else { return nil }
        let count = text.prefix { $0 == char }.count
        guard count >= 3, char == "~" || !text.dropFirst(count).contains("`") else { return nil }
        return Fence(char: char, count: count, indent: depth)
    }

    static func closes(_ line: String, _ fence: Fence) -> Bool {
        let text = trimmedLeading(line)
        let count = text.prefix { $0 == fence.char }.count
        return indent(line) < 4 && count >= fence.count && isBlank(String(text.dropFirst(count)))
    }

    static func quoteContent(_ line: String) -> String? {
        let text = trimmedLeading(line)
        guard indent(line) < 4, text.first == ">" else { return nil }
        let rest = text.dropFirst()
        switch rest.first {
        case " ": return String(rest.dropFirst())
        case "\t": return "  " + rest.dropFirst()
        default: return String(rest)
        }
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let depth = indent(line)
        let text = trimmedLeading(line)
        guard depth < 4, let first = text.first else { return nil }
        var length = 1
        var number = 0
        var delimiter = first
        if !"-+*".contains(first) {
            let digits = text.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let next = text.dropFirst(digits.count).first, next == "." || next == ")" else { return nil }
            length = digits.count + 1
            number = Int(digits) ?? 0
            delimiter = next
        }
        let rest = String(text.dropFirst(length))
        let ordered = number > 0 || delimiter != first
        if isBlank(rest) {
            guard rest.isEmpty || isSpace(rest.first ?? " ") else { return nil }
            return ListMarker(ordered: ordered, delimiter: delimiter, number: number, width: depth + length + 1, content: "")
        }
        guard let space = rest.first, isSpace(space) else { return nil }
        let gap = indent(rest) >= 5 ? 1 : indent(rest)
        return ListMarker(ordered: ordered, delimiter: delimiter, number: number, width: depth + length + gap,
                          content: stripped(rest, columns: gap))
    }

    static func htmlStart(_ line: String, interrupting: Bool) -> HtmlEnd? {
        guard indent(line) < 4 else { return nil }
        let text = Array(trimmedLeading(line))
        guard text.first == "<" else { return nil }
        let lower = String(text).lowercased()
        let closing = text.count > 1 && text[1] == "/"
        let name = String(lower.dropFirst(closing ? 2 : 1).prefix { $0.isASCII && ($0.isLetter || $0.isNumber) })
        let after = lower.dropFirst((closing ? 2 : 1) + name.count)
        if !closing, rawTags.contains(name), after.first.map({ $0 == ">" || isSpace($0) }) ?? true {
            return .marker(rawTags.map { "</\($0)>" })
        }
        if lower.hasPrefix("<!--") { return .marker(["-->"]) }
        if lower.hasPrefix("<?") { return .marker(["?>"]) }
        if lower.hasPrefix("<![cdata[") { return .marker(["]]>"]) }
        if text.count > 2, text[1] == "!", text[2].isASCII, text[2].isLetter { return .marker([">"]) }
        if blockTags.contains(name), after.isEmpty || after.hasPrefix(">") || after.hasPrefix("/>") || isSpace(after.first ?? "x") {
            return .blankLine
        }
        guard !interrupting, !rawTags.contains(name), let end = MarkdownHTML.tagEnd(text, from: 0),
              isBlank(String(text[end...])) else { return nil }
        return .blankLine
    }

    /// startsBlock reports whether `line` opens a block. Interrupting a paragraph in the same container, a list
    /// must open with a non-empty item numbered 1 and a bare-tag HTML block cannot start.
    static func startsBlock(_ line: String, interrupting: Bool) -> Bool {
        guard !isBlank(line), indent(line) < 4 else { return false }
        if isThematicBreak(line) || atxHeading(line) != nil || fenceOpen(line) != nil || quoteContent(line) != nil
            || htmlStart(line, interrupting: interrupting) != nil {
            return true
        }
        guard let marker = listMarker(line) else { return false }
        return !interrupting || (!isBlank(marker.content) && (!marker.ordered || marker.number == 1))
    }
}

private enum MarkdownTable {
    /// cells splits a row at unescaped pipes, dropping the optional outer ones; `\|` becomes a literal pipe.
    static func cells(_ line: String) -> [String] {
        var text = Substring(MarkdownLine.trimmed(line))
        if text.hasPrefix("|") { text = text.dropFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text = text.dropLast() }
        var cells = [""]
        var escaped = false
        for char in text {
            if escaped {
                cells[cells.count - 1] += char == "|" ? "|" : "\\" + String(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "|" {
                cells.append("")
            } else {
                cells[cells.count - 1].append(char)
            }
        }
        if escaped { cells[cells.count - 1] += "\\" }
        return cells.map(MarkdownLine.trimmed)
    }

    static func delimiterColumns(_ line: String) -> Int? {
        guard MarkdownLine.indent(line) < 4, line.contains("|") else { return nil }
        let cells = cells(line)
        let valid = cells.allSatisfy { cell in
            let dashes = cell.drop { $0 == ":" }.reversed().drop { $0 == ":" }
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" } && cell.count - dashes.count <= 2
        }
        return valid ? cells.count : nil
    }
}

// MARK: - blocks

private enum MarkdownBlockParser {
    static func parse(_ lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count { index = parseBlock(lines, at: index, into: &blocks) }
        return blocks
    }

    private static func parseBlock(_ lines: [String], at index: Int, into blocks: inout [MarkdownBlock]) -> Int {
        let line = lines[index]
        if MarkdownLine.isBlank(line) { return index + 1 }
        if MarkdownLine.indent(line) >= 4 { return indentedCode(lines, at: index, into: &blocks) }
        if MarkdownLine.isThematicBreak(line) {
            blocks.append(.rule)
            return index + 1
        }
        if let heading = MarkdownLine.atxHeading(line) {
            blocks.append(.heading(heading))
            return index + 1
        }
        if let fence = MarkdownLine.fenceOpen(line) { return fencedCode(lines, at: index, fence: fence, into: &blocks) }
        if MarkdownLine.quoteContent(line) != nil { return quote(lines, at: index, into: &blocks) }
        if let end = MarkdownLine.htmlStart(line, interrupting: false) { return html(lines, at: index, end: end, into: &blocks) }
        if let marker = MarkdownLine.listMarker(line) { return list(lines, at: index, first: marker, into: &blocks) }
        return paragraph(lines, at: index, into: &blocks)
    }

    private static func paragraph(_ lines: [String], at start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var body = [MarkdownLine.trimmedLeading(lines[start])]
        var index = start + 1
        while index < lines.count, !MarkdownLine.isBlank(lines[index]) {
            let line = lines[index]
            if let columns = MarkdownTable.delimiterColumns(line), let header = body.last,
               MarkdownTable.cells(header).count == columns {
                body.removeLast()
                if !body.isEmpty { blocks.append(.paragraph(joined(body))) }
                return table(lines, at: index + 1, header: MarkdownTable.cells(header), into: &blocks)
            }
            if MarkdownLine.isSetextUnderline(line) {
                blocks.append(.heading(joined(body)))
                return index + 1
            }
            if MarkdownLine.startsBlock(line, interrupting: true) { break }
            body.append(MarkdownLine.trimmedLeading(line))
            index += 1
        }
        blocks.append(.paragraph(joined(body)))
        return index
    }

    private static func joined(_ body: [String]) -> String {
        String(body.joined(separator: "\n").reversed().drop(while: MarkdownLine.isSpace).reversed())
    }

    private static func table(_ lines: [String], at start: Int, header: [String], into blocks: inout [MarkdownBlock]) -> Int {
        var rows: [[String]] = []
        var index = start
        while index < lines.count, !MarkdownLine.isBlank(lines[index]), !MarkdownLine.startsBlock(lines[index], interrupting: true) {
            rows.append(MarkdownTable.cells(lines[index]))
            index += 1
        }
        blocks.append(.table(header: header, rows: rows))
        return index
    }

    private static func indentedCode(_ lines: [String], at start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var body: [String] = []
        var index = start
        while index < lines.count, MarkdownLine.isBlank(lines[index]) || MarkdownLine.indent(lines[index]) >= 4 {
            body.append(MarkdownLine.stripped(lines[index], columns: 4))
            index += 1
        }
        while let last = body.last, MarkdownLine.isBlank(last) { body.removeLast() }
        blocks.append(.code(body))
        return index
    }

    private static func fencedCode(_ lines: [String], at start: Int, fence: Fence, into blocks: inout [MarkdownBlock]) -> Int {
        var body: [String] = []
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            index += 1
            if MarkdownLine.closes(line, fence) { break }
            body.append(MarkdownLine.stripped(line, columns: fence.indent))
        }
        blocks.append(.code(body))
        return index
    }

    private static func html(_ lines: [String], at start: Int, end: HtmlEnd, into blocks: inout [MarkdownBlock]) -> Int {
        var body: [String] = []
        var index = start
        while index < lines.count {
            let line = lines[index]
            if case .blankLine = end, MarkdownLine.isBlank(line) { break }
            body.append(line)
            index += 1
            if case .marker(let markers) = end, markers.contains(where: line.lowercased().contains) { break }
        }
        blocks.append(.html(body))
        return index
    }

    private static func quote(_ lines: [String], at start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var body: [String] = []
        var index = start
        while index < lines.count {
            let line = lines[index]
            if let content = MarkdownLine.quoteContent(line) {
                body.append(content)
            } else if isLazy(line, after: body) {
                body.append(line)
            } else {
                break
            }
            index += 1
        }
        blocks.append(.quote(parse(body)))
        return index
    }

    private static func list(_ lines: [String], at start: Int, first: ListMarker, into blocks: inout [MarkdownBlock]) -> Int {
        var items: [[MarkdownBlock]] = []
        var index = start
        var marker = first
        while true {
            let (body, next) = item(lines, at: index, marker: marker)
            items.append(parse(body))
            index = next
            var probe = index
            while probe < lines.count, MarkdownLine.isBlank(lines[probe]) { probe += 1 }
            guard probe < lines.count, !MarkdownLine.isThematicBreak(lines[probe]),
                  let following = MarkdownLine.listMarker(lines[probe]), following.continues(first) else { break }
            index = probe
            marker = following
        }
        blocks.append(.list(ordered: first.ordered, start: first.number, items: items))
        return index
    }

    /// item gathers the lines of one list item, content column stripped, and the index after its last non-blank line.
    private static func item(_ lines: [String], at start: Int, marker: ListMarker) -> ([String], Int) {
        var body = [marker.content]
        var index = start + 1
        var end = index
        if MarkdownLine.isBlank(marker.content), index < lines.count, MarkdownLine.isBlank(lines[index]) { return ([], index) }
        while index < lines.count {
            let line = lines[index]
            if MarkdownLine.isBlank(line) {
                body.append("")
            } else if MarkdownLine.indent(line) >= marker.width {
                body.append(MarkdownLine.stripped(line, columns: marker.width))
            } else if isLazy(line, after: body) {
                body.append(line)
            } else {
                break
            }
            index += 1
            if !MarkdownLine.isBlank(line) { end = index }
        }
        return (Array(body.prefix(end - start)), end)
    }

    /// isLazy reports whether `line` continues a paragraph left open at the end of `body` without its container's prefix.
    private static func isLazy(_ line: String, after body: [String]) -> Bool {
        guard !MarkdownLine.isBlank(line), let last = body.last, !MarkdownLine.isBlank(last),
              !MarkdownLine.startsBlock(line, interrupting: false) else { return false }
        return endsInParagraph(parse(body))
    }

    private static func endsInParagraph(_ blocks: [MarkdownBlock]) -> Bool {
        switch blocks.last {
        case .paragraph: true
        case .quote(let inner): endsInParagraph(inner)
        case .list(_, _, let items): endsInParagraph(items.last ?? [])
        default: false
        }
    }
}

private enum MarkdownDefinitions {
    /// extracting moves link reference definitions opening a paragraph into `definitions`, the first one winning.
    static func extracting(_ blocks: [MarkdownBlock], into definitions: inout [String: String]) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        for block in blocks {
            switch block {
            case .paragraph(let text):
                let rest = MarkdownReference.extract(text, into: &definitions)
                if !rest.isEmpty { out.append(.paragraph(rest)) }
            case .quote(let inner):
                out.append(.quote(extracting(inner, into: &definitions)))
            case let .list(ordered, start, items):
                out.append(.list(ordered: ordered, start: start, items: items.map { extracting($0, into: &definitions) }))
            default:
                out.append(block)
            }
        }
        return out
    }
}

// MARK: - rendering

private struct MarkdownRenderer {
    enum Container {
        case quote
        case list(id: Int)
        case item(id: Int, marker: String)
    }

    let definitions: [String: String]
    var out: [HudMarkdown.Line] = []
    var seenItems: Set<Int> = []
    var lastListIDs: Set<Int>?
    var nextID = 0

    mutating func render(_ blocks: [MarkdownBlock], in containers: [Container]) {
        for block in blocks {
            switch block {
            case .quote(let inner):
                render(inner, in: containers + [.quote])
            case let .list(ordered, start, items):
                let listID = newID()
                for (offset, item) in items.enumerated() {
                    let marker = ordered ? "\(start + offset). " : HudMarkdown.bullet
                    render(item, in: containers + [.list(id: listID), .item(id: newID(), marker: marker)])
                }
            case .html(var body):
                // Foundation gives a raw HTML block no block intent, so it drops its containers' prefixes too
                while body.last?.isEmpty == true { body.removeLast() }
                emit(body.map { HudMarkdown.Line(lead: "", hang: "", runs: [HudMarkdown.Run(text: HudMarkdown.sanitized($0), style: [])]) },
                     in: [])
            case .table(let header, let rows):
                table(header: header, rows: rows, in: containers)
            default:
                leaf(block, in: containers)
            }
        }
    }

    private mutating func newID() -> Int {
        nextID += 1
        return nextID
    }

    private mutating func leaf(_ block: MarkdownBlock, in containers: [Container]) {
        switch block {
        case .paragraph(let text), .heading(let text):
            let segments = MarkdownInline.segments(text, definitions: definitions)
            guard !segments.isEmpty else { return }
            let base: HudMarkdown.Style = if case .heading = block { .bold } else { [] }
            let (lead, hang) = prefixes(containers)
            let rows = MarkdownInline.rows(segments, base: base)
            emit(rows.enumerated().map { HudMarkdown.Line(lead: $0.offset == 0 ? lead : hang, hang: hang, runs: $0.element) },
                 in: containers)
        case .code(let body):
            guard !body.isEmpty else { return }
            let (lead, hang) = prefixes(containers)
            emit(body.enumerated().map { index, raw in
                HudMarkdown.Line(lead: (index == 0 ? lead : hang) + HudMarkdown.codeIndent, hang: hang + HudMarkdown.codeIndent,
                                 runs: [HudMarkdown.Run(text: HudMarkdown.sanitized(HudMarkdown.expandTabs(raw)), style: [])],
                                 kind: .code)
            }, in: containers)
        case .rule:
            let (lead, hang) = prefixes(containers)
            emit([HudMarkdown.Line(lead: lead, hang: hang, runs: [], kind: .rule)], in: containers)
        default:
            return
        }
    }

    /// table mirrors the walker's framing: Foundation emits no run for an empty cell, so an all-empty header
    /// has no header rule, trailing all-empty rows vanish, and a table with no content emits nothing.
    private mutating func table(header: [String], rows: [[String]], in containers: [Container]) {
        let columns = header.count
        func cells(_ row: [String], base: HudMarkdown.Style) -> [[HudMarkdown.Run]] {
            (0..<columns).map { index in
                index < row.count ? MarkdownInline.rows(MarkdownInline.segments(row[index], definitions: definitions), base: base)
                    .flatMap { $0 } : []
            }
        }
        let head = cells(header, base: .bold)
        var body = rows.map { cells($0, base: []) }
        while let last = body.last, last.allSatisfy(\.isEmpty) { body.removeLast() }
        let hasHeader = head.contains { !$0.isEmpty }
        let grid = (hasHeader ? [head] : []) + body
        guard !grid.isEmpty else { return }
        var widths = [Int](repeating: 0, count: columns)
        for row in grid {
            for (index, cell) in row.enumerated() { widths[index] = max(widths[index], HudMarkdown.width(cell)) }
        }
        func border(_ left: String, _ join: String, _ right: String) -> [HudMarkdown.Run] {
            [HudMarkdown.Run(text: left + widths.map { String(repeating: "─", count: $0 + 2) }.joined(separator: join) + right, style: [])]
        }
        func framed(_ row: [[HudMarkdown.Run]]) -> [HudMarkdown.Run] {
            var runs = [HudMarkdown.Run(text: "│ ", style: [])]
            for (index, cell) in row.enumerated() {
                if index > 0 { runs.append(HudMarkdown.Run(text: " ", style: [])) }
                runs += cell
                let pad = String(repeating: " ", count: widths[index] - HudMarkdown.width(cell) + 1)
                runs.append(HudMarkdown.Run(text: pad + "│", style: []))
            }
            return runs
        }
        var framedRows = [border("┌", "┬", "┐")]
        for (offset, row) in grid.enumerated() {
            framedRows.append(framed(row))
            if offset == 0, hasHeader { framedRows.append(border("├", "┼", "┤")) }
        }
        framedRows.append(border("└", "┴", "┘"))
        let (lead, hang) = prefixes(containers)
        emit(framedRows.enumerated().map { HudMarkdown.Line(lead: $0.offset == 0 ? lead : hang, hang: hang, runs: $0.element, kind: .table) },
             in: containers)
    }

    private mutating func emit(_ lines: [HudMarkdown.Line], in containers: [Container]) {
        guard !lines.isEmpty else { return }
        let listIDs = Set(containers.compactMap { container -> Int? in
            if case .list(let id) = container { return id }
            return nil
        })
        if let last = lastListIDs, last.isDisjoint(with: listIDs) || listIDs.isEmpty { out.append(.blank) }
        lastListIDs = listIDs
        out += lines
    }

    private mutating func prefixes(_ containers: [Container]) -> (String, String) {
        var lead = ""
        var hang = ""
        for container in containers {
            switch container {
            case .quote:
                lead += HudMarkdown.quoteBar
                hang += HudMarkdown.quoteBar
            case .list:
                break
            case let .item(id, marker):
                let pad = String(repeating: " ", count: HudLayout.cellCount(marker))
                lead += seenItems.insert(id).inserted ? marker : pad
                hang += pad
            }
        }
        return (lead, hang)
    }
}
#endif
