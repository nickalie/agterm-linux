#if !canImport(Darwin)
import Foundation

// The inline half of the Linux markdown parser in `HudMarkdown+Portable.swift`: CommonMark inlines plus GFM
// strikethrough, flattened into segments split wherever Foundation would split its attributed runs.

enum MarkdownInline {
    enum Kind { case text, softBreak, lineBreak }

    struct Segment {
        var text: String
        let style: HudMarkdown.Style
        /// mark stands for the non-style attributes (code, HTML, link target) that split Foundation's runs.
        let mark: String
        let kind: Kind
    }

    static func segments(_ text: String, definitions: [String: String]) -> [Segment] {
        var parser = InlineParser(chars: Array(text), definitions: definitions)
        parser.run()
        var out: [Segment] = []
        flatten(emphasized(parser.items), style: [], mark: "", into: &out)
        return out
    }

    /// rows maps segments onto runs over `base` and splits at hard breaks; a soft break is a space.
    static func rows(_ segments: [Segment], base: HudMarkdown.Style) -> [[HudMarkdown.Run]] {
        var rows: [[HudMarkdown.Run]] = [[]]
        for segment in segments {
            if segment.kind == .lineBreak {
                rows.append([])
                continue
            }
            let text = segment.kind == .softBreak ? " " : HudMarkdown.sanitized(segment.text)
            rows[rows.count - 1].append(HudMarkdown.Run(text: text, style: base.union(segment.style)))
        }
        return rows
    }

    /// flatten merges adjacent text with equal style and mark, as Foundation merges runs with equal attributes.
    private static func flatten(_ nodes: [InlineNode], style: HudMarkdown.Style, mark: String, into out: inout [Segment]) {
        for node in nodes {
            switch node {
            case .text(let text): append(Segment(text: text, style: style, mark: mark, kind: .text), to: &out)
            case .code(let text): append(Segment(text: text, style: style, mark: mark + "|code", kind: .text), to: &out)
            case .html(let text): append(Segment(text: text, style: style, mark: mark + "|html", kind: .text), to: &out)
            case .softBreak: out.append(Segment(text: "", style: style, mark: mark, kind: .softBreak))
            case .lineBreak: out.append(Segment(text: "", style: style, mark: mark, kind: .lineBreak))
            case let .span(added, children): flatten(children, style: style.union(added), mark: mark, into: &out)
            case let .link(target, children): flatten(children, style: style, mark: mark + "|" + target, into: &out)
            }
        }
    }

    private static func append(_ segment: Segment, to out: inout [Segment]) {
        guard !segment.text.isEmpty else { return }
        if let last = out.last, last.kind == .text, last.style == segment.style, last.mark == segment.mark {
            out[out.count - 1].text += segment.text
        } else {
            out.append(segment)
        }
    }

    /// emphasized pairs delimiter runs into spans by CommonMark's process-emphasis rules; `~` pairs only with an
    /// equal run, as GFM strikethrough does. Unpaired delimiters stay literal text.
    fileprivate static func emphasized(_ input: [InlineItem]) -> [InlineNode] {
        var items = input
        var bottoms: [String: Int] = [:]
        var closerIndex = 0
        while closerIndex < items.count {
            guard case .delimiter(var closer) = items[closerIndex], closer.canClose else {
                closerIndex += 1
                continue
            }
            let key = "\(closer.char)\(closer.canOpen)\(closer.original % 3)"
            guard let openerIndex = opener(for: closer, in: items, below: closerIndex, above: bottoms[key] ?? -1),
                  case .delimiter(var opener) = items[openerIndex] else {
                bottoms[key] = closerIndex - 1
                closerIndex += 1
                continue
            }
            let used = closer.char == "~" ? closer.count : min(2, opener.count, closer.count)
            let style: HudMarkdown.Style = closer.char == "~" ? .strikethrough : used == 2 ? .bold : .italic
            let inner = items[(openerIndex + 1)..<closerIndex].map(literal)
            opener.count -= used
            closer.count -= used
            var replacement: [InlineItem] = opener.count > 0 ? [.delimiter(opener)] : []
            replacement.append(.node(.span(style, inner)))
            if closer.count > 0 { replacement.append(.delimiter(closer)) }
            items.replaceSubrange(openerIndex...closerIndex, with: replacement)
            let floor = opener.count > 0 ? openerIndex : openerIndex - 1
            bottoms = bottoms.mapValues { min($0, floor) }
            closerIndex = floor + 2
        }
        return items.map(literal)
    }

    private static func opener(for closer: Delimiter, in items: [InlineItem], below closerIndex: Int, above bottom: Int) -> Int? {
        var index = closerIndex - 1
        while index > bottom {
            if case .delimiter(let opener) = items[index], opener.char == closer.char, opener.canOpen, opener.count > 0,
               pairs(opener, closer) {
                return index
            }
            index -= 1
        }
        return nil
    }

    /// pairs applies the rule of three, under which a run that can both open and close pairs only when the
    /// two lengths do not sum to a multiple of three.
    private static func pairs(_ opener: Delimiter, _ closer: Delimiter) -> Bool {
        if closer.char == "~" { return opener.count == closer.count }
        guard opener.canClose || closer.canOpen else { return true }
        return (opener.original + closer.original) % 3 != 0 || (opener.original % 3 == 0 && closer.original % 3 == 0)
    }

    private static func literal(_ item: InlineItem) -> InlineNode {
        switch item {
        case .node(let node): node
        case .delimiter(let delimiter): .text(String(repeating: delimiter.char, count: delimiter.count))
        }
    }
}

enum MarkdownReference {
    static func normalized(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// extract moves the link reference definitions opening `text` into `definitions`, the first one winning,
    /// and returns the rest.
    static func extract(_ text: String, into definitions: inout [String: String]) -> String {
        let chars = Array(text)
        var start = 0
        while let (label, destination, end) = definition(chars, from: start) {
            let key = normalized(label)
            if definitions[key] == nil { definitions[key] = destination }
            start = end
        }
        return String(chars[start...])
    }

    private static func definition(_ chars: [Character], from start: Int) -> (String, String, Int)? {
        guard let (label, afterLabel) = MarkdownScan.label(chars, from: start), afterLabel < chars.count, chars[afterLabel] == ":",
              label.contains(where: { !$0.isWhitespace }) else { return nil }
        let destinationStart = MarkdownScan.skipWhitespace(chars, from: afterLabel + 1)
        guard let (destination, afterDestination) = MarkdownScan.destination(chars, from: destinationStart),
              afterDestination > destinationStart else { return nil }
        let titleStart = MarkdownScan.skipWhitespace(chars, from: afterDestination)
        if titleStart > afterDestination, let afterTitle = MarkdownScan.title(chars, from: titleStart),
           let end = lineEnd(chars, from: afterTitle) {
            return (label, destination, end)
        }
        guard let end = lineEnd(chars, from: afterDestination) else { return nil }
        return (label, destination, end)
    }

    private static func lineEnd(_ chars: [Character], from start: Int) -> Int? {
        var index = start
        while index < chars.count, MarkdownScan.isSpace(chars[index]) { index += 1 }
        if index == chars.count { return index }
        return chars[index] == "\n" ? index + 1 : nil
    }
}

enum MarkdownHTML {
    /// tagEnd returns the index after the raw HTML tag, comment, declaration, processing instruction or CDATA at `start`.
    static func tagEnd(_ chars: [Character], from start: Int) -> Int? {
        guard start + 1 < chars.count, chars[start] == "<" else { return nil }
        switch chars[start + 1] {
        case "/":
            guard let index = name(chars, from: start + 2) else { return nil }
            let close = MarkdownScan.skipWhitespace(chars, from: index)
            return close < chars.count && chars[close] == ">" ? close + 1 : nil
        case "?":
            return end(of: "?>", in: chars, from: start + 2)
        case "!":
            return declarationEnd(chars, from: start + 2)
        default:
            return openEnd(chars, from: start + 1)
        }
    }

    private static func name(_ chars: [Character], from start: Int) -> Int? {
        guard start < chars.count, chars[start].isASCII, chars[start].isLetter else { return nil }
        var index = start + 1
        while index < chars.count, chars[index].isASCII, chars[index].isLetter || chars[index].isNumber || chars[index] == "-" { index += 1 }
        return index
    }

    private static func openEnd(_ chars: [Character], from start: Int) -> Int? {
        guard var index = name(chars, from: start) else { return nil }
        while true {
            let spaced = MarkdownScan.skipWhitespace(chars, from: index)
            guard spaced < chars.count else { return nil }
            if chars[spaced] == ">" { return spaced + 1 }
            if chars[spaced] == "/" { return spaced + 1 < chars.count && chars[spaced + 1] == ">" ? spaced + 2 : nil }
            guard spaced > index, let next = attribute(chars, from: spaced) else { return nil }
            index = next
        }
    }

    private static func attribute(_ chars: [Character], from start: Int) -> Int? {
        func isNameChar(_ char: Character) -> Bool { char.isASCII && (char.isLetter || char.isNumber || "_.:-".contains(char)) }
        guard chars[start].isASCII, chars[start].isLetter || chars[start] == "_" || chars[start] == ":" else { return nil }
        var index = start + 1
        while index < chars.count, isNameChar(chars[index]) { index += 1 }
        let equals = MarkdownScan.skipWhitespace(chars, from: index)
        guard equals < chars.count, chars[equals] == "=" else { return index }
        let value = MarkdownScan.skipWhitespace(chars, from: equals + 1)
        guard value < chars.count else { return nil }
        if chars[value] == "\"" || chars[value] == "'" {
            return chars[(value + 1)...].firstIndex(of: chars[value]).map { $0 + 1 }
        }
        var end = value
        while end < chars.count, !chars[end].isWhitespace, !"\"'=<>`".contains(chars[end]) { end += 1 }
        return end > value ? end : nil
    }

    private static func declarationEnd(_ chars: [Character], from start: Int) -> Int? {
        if starts(chars, "-->", at: start) { return start + 3 }
        if starts(chars, "--->", at: start) { return start + 4 }
        if starts(chars, "--", at: start) { return end(of: "-->", in: chars, from: start + 2) }
        if starts(chars, "[CDATA[", at: start) { return end(of: "]]>", in: chars, from: start + 7) }
        guard start < chars.count, chars[start].isASCII, chars[start].isLetter else { return nil }
        return end(of: ">", in: chars, from: start)
    }

    private static func starts(_ chars: [Character], _ marker: String, at start: Int) -> Bool {
        let marker = Array(marker)
        return start + marker.count <= chars.count && Array(chars[start..<(start + marker.count)]) == marker
    }

    private static func end(of marker: String, in chars: [Character], from start: Int) -> Int? {
        var index = start
        while index + marker.count <= chars.count {
            if starts(chars, marker, at: index) { return index + marker.count }
            index += 1
        }
        return nil
    }
}

private enum MarkdownScan {
    static let escapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    static func isSpace(_ char: Character) -> Bool { char == " " || char == "\t" }

    /// skipWhitespace skips spaces, tabs and at most one line ending.
    static func skipWhitespace(_ chars: [Character], from start: Int) -> Int {
        var index = start
        var newline = false
        while index < chars.count, isSpace(chars[index]) || chars[index] == "\n" {
            if chars[index] == "\n" {
                if newline { break }
                newline = true
            }
            index += 1
        }
        return index
    }

    /// label reads a bracketed link label, returning its raw text and the index after the closing bracket.
    static func label(_ chars: [Character], from start: Int) -> (String, Int)? {
        guard start < chars.count, chars[start] == "[" else { return nil }
        var index = start + 1
        var text = ""
        while index < chars.count, chars[index] != "]" {
            if chars[index] == "[" { return nil }
            if chars[index] == "\\", index + 1 < chars.count, escapable.contains(chars[index + 1]) {
                text.append(chars[index])
                index += 1
            }
            text.append(chars[index])
            index += 1
        }
        guard index < chars.count, text.count <= 999 else { return nil }
        return (text, index + 1)
    }

    /// destination reads a link destination, bare with balanced parentheses or in angle brackets.
    static func destination(_ chars: [Character], from start: Int) -> (String, Int)? {
        var index = start
        var text = ""
        if index < chars.count, chars[index] == "<" {
            index += 1
            while index < chars.count, chars[index] != ">" {
                if chars[index] == "\n" || chars[index] == "<" { return nil }
                if chars[index] == "\\", index + 1 < chars.count, escapable.contains(chars[index + 1]) { index += 1 }
                text.append(chars[index])
                index += 1
            }
            return index < chars.count ? (text, index + 1) : nil
        }
        var depth = 0
        while index < chars.count, !chars[index].isWhitespace, !(chars[index] == ")" && depth == 0) {
            if chars[index] == "\\", index + 1 < chars.count, escapable.contains(chars[index + 1]) { index += 1 }
            if chars[index] == "(" { depth += 1 }
            if chars[index] == ")" { depth -= 1 }
            text.append(chars[index])
            index += 1
        }
        return depth == 0 ? (text, index) : nil
    }

    /// title reads a quoted or parenthesized link title, returning the index after it.
    static func title(_ chars: [Character], from start: Int) -> Int? {
        let closers: [Character: Character] = ["\"": "\"", "'": "'", "(": ")"]
        guard start < chars.count, let close = closers[chars[start]] else { return nil }
        var index = start + 1
        while index < chars.count, chars[index] != close {
            if chars[index] == "\\" { index += 1 }
            index += 1
        }
        return index < chars.count ? index + 1 : nil
    }
}

private enum MarkdownEntity {
    /// named covers the common HTML entities; an unknown name stays literal text.
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”",
        "bdquo": "„", "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "bull": "•", "middot": "·", "times": "×",
        "divide": "÷", "deg": "°", "plusmn": "±", "micro": "µ", "para": "¶", "sect": "§", "cent": "¢", "pound": "£",
        "yen": "¥", "euro": "€", "curren": "¤", "iexcl": "¡", "iquest": "¿", "shy": "\u{AD}", "ensp": "\u{2002}",
        "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "larr": "←", "rarr": "→", "uarr": "↑",
        "darr": "↓", "harr": "↔", "lArr": "⇐", "rArr": "⇒", "hArr": "⇔", "check": "✓", "cross": "✗", "star": "☆",
        "starf": "★", "hearts": "♥", "spades": "♠", "clubs": "♣", "diams": "♦", "infin": "∞", "ne": "≠", "le": "≤",
        "ge": "≥", "asymp": "≈", "minus": "−", "sum": "∑", "prod": "∏", "radic": "√", "part": "∂", "forall": "∀", "exist": "∃",
        "empty": "∅", "isin": "∈", "notin": "∉", "and": "∧", "or": "∨", "cap": "∩", "cup": "∪", "int": "∫", "there4": "∴",
        "prime": "′", "Prime": "″", "dagger": "†", "Dagger": "‡", "permil": "‰", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "sup1": "¹", "sup2": "²", "sup3": "³", "ordf": "ª", "ordm": "º", "not": "¬", "macr": "¯", "acute": "´", "uml": "¨",
        "cedil": "¸", "brvbar": "¦", "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "lambda": "λ",
        "mu": "μ", "pi": "π", "sigma": "σ", "tau": "τ", "phi": "φ", "omega": "ω", "Delta": "Δ", "Sigma": "Σ", "Omega": "Ω",
        "Tab": "\t", "NewLine": "\n", "excl": "!", "num": "#", "dollar": "$", "percnt": "%", "lpar": "(", "rpar": ")",
        "ast": "*", "plus": "+", "comma": ",", "period": ".", "sol": "/", "colon": ":", "semi": ";", "equals": "=",
        "quest": "?", "commat": "@", "lsqb": "[", "rsqb": "]", "bsol": "\\", "lowbar": "_", "grave": "`", "lcub": "{",
        "rcub": "}", "verbar": "|", "vert": "|", "tilde": "˜", "Hat": "^"
    ]

    /// decode reads the entity or numeric character reference at `start`, returning its text and the index after it.
    static func decode(_ chars: [Character], from start: Int) -> (String, Int)? {
        var index = start + 1
        guard index < chars.count else { return nil }
        if chars[index] == "#" {
            index += 1
            let hex = index < chars.count && (chars[index] == "x" || chars[index] == "X")
            if hex { index += 1 }
            let digits = chars[index...].prefix { hex ? $0.isHexDigit : $0.isASCII && $0.isNumber }
            let end = index + digits.count
            guard (1...(hex ? 6 : 7)).contains(digits.count), end < chars.count, chars[end] == ";" else { return nil }
            let value = UInt32(String(digits), radix: hex ? 16 : 10) ?? 0
            let scalar = value == 0 ? nil : Unicode.Scalar(value)
            return (String(Character(scalar ?? "\u{FFFD}")), end + 1)
        }
        let name = chars[index...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let end = index + name.count
        guard end < chars.count, chars[end] == ";", let value = named[String(name)] else { return nil }
        return (value, end + 1)
    }
}

private indirect enum InlineNode {
    case text(String)
    case code(String)
    case html(String)
    case softBreak
    case lineBreak
    case span(HudMarkdown.Style, [InlineNode])
    /// link carries its target, so adjacent links split runs as Foundation's link attribute does.
    case link(String, [InlineNode])
}

private struct Delimiter {
    let char: Character
    var count: Int
    let original: Int
    let canOpen: Bool
    let canClose: Bool
}

private enum InlineItem {
    case node(InlineNode)
    case delimiter(Delimiter)
}

private struct InlineParser {
    struct Bracket {
        let index: Int
        let image: Bool
        var active: Bool
        let textStart: Int
    }

    let chars: [Character]
    let definitions: [String: String]
    var pos = 0
    var items: [InlineItem] = []
    var brackets: [Bracket] = []
    var pending = ""

    init(chars: [Character], definitions: [String: String]) {
        self.chars = chars
        self.definitions = definitions
    }

    mutating func run() {
        while pos < chars.count {
            let char = chars[pos]
            switch char {
            case "\\": escape()
            case "`": codeSpan()
            case "*", "_", "~": delimiterRun(char)
            case "[": openBracket(image: false)
            case "!" where peek(1) == "[": openBracket(image: true)
            case "]": closeBracket()
            case "<": angle()
            case "&": entity()
            case "\n": lineEnd()
            default:
                pending.append(char)
                pos += 1
            }
        }
        flush()
    }

    private func peek(_ offset: Int) -> Character? { pos + offset < chars.count ? chars[pos + offset] : nil }

    private mutating func flush() {
        guard !pending.isEmpty else { return }
        items.append(.node(.text(pending)))
        pending = ""
    }

    private mutating func push(_ node: InlineNode) {
        flush()
        items.append(.node(node))
    }

    private mutating func skipLeadingSpaces() {
        while pos < chars.count, MarkdownScan.isSpace(chars[pos]) { pos += 1 }
    }

    private mutating func escape() {
        if peek(1) == "\n" {
            push(.lineBreak)
            pos += 2
            skipLeadingSpaces()
        } else if let next = peek(1), MarkdownScan.escapable.contains(next) {
            pending.append(next)
            pos += 2
        } else {
            pending.append("\\")
            pos += 1
        }
    }

    /// lineEnd drops the spaces ending a line, two or more of them making it a hard break.
    private mutating func lineEnd() {
        let trailing = pending.reversed().prefix { $0 == " " }.count
        pending.removeLast(trailing)
        push(trailing >= 2 ? .lineBreak : .softBreak)
        pos += 1
        skipLeadingSpaces()
    }

    private func runLength(at start: Int, of char: Character) -> Int {
        var end = start
        while end < chars.count, chars[end] == char { end += 1 }
        return end - start
    }

    private mutating func codeSpan() {
        let length = runLength(at: pos, of: "`")
        var index = pos + length
        while index < chars.count {
            guard chars[index] == "`" else {
                index += 1
                continue
            }
            let closing = runLength(at: index, of: "`")
            if closing == length {
                var content = String(chars[(pos + length)..<index]).replacingOccurrences(of: "\n", with: " ")
                if content.count > 1, content.first == " ", content.last == " ", content.contains(where: { $0 != " " }) {
                    content = String(content.dropFirst().dropLast())
                }
                push(.code(content))
                pos = index + closing
                return
            }
            index += closing
        }
        pending += String(repeating: "`", count: length)
        pos += length
    }

    /// delimiterRun classifies a `*`, `_` or `~` run by CommonMark's flanking rules.
    private mutating func delimiterRun(_ char: Character) {
        let count = runLength(at: pos, of: char)
        let before: Character = pos > 0 ? chars[pos - 1] : "\n"
        let after: Character = pos + count < chars.count ? chars[pos + count] : "\n"
        let left = !after.isWhitespace && (!Self.isPunctuation(after) || before.isWhitespace || Self.isPunctuation(before))
        let right = !before.isWhitespace && (!Self.isPunctuation(before) || after.isWhitespace || Self.isPunctuation(after))
        let canOpen = char == "_" ? left && (!right || Self.isPunctuation(before)) : left
        let canClose = char == "_" ? right && (!left || Self.isPunctuation(after)) : right
        pos += count
        guard canOpen || canClose, char != "~" || count <= 2 else {
            pending += String(repeating: char, count: count)
            return
        }
        flush()
        items.append(.delimiter(Delimiter(char: char, count: count, original: count, canOpen: canOpen, canClose: canClose)))
    }

    private static func isPunctuation(_ char: Character) -> Bool {
        char.isASCII ? MarkdownScan.escapable.contains(char) : char.isPunctuation
    }

    private mutating func openBracket(image: Bool) {
        let length = image ? 2 : 1
        push(.text(image ? "![" : "["))
        brackets.append(Bracket(index: items.count - 1, image: image, active: true, textStart: pos + length))
        pos += length
    }

    private mutating func closeBracket() {
        guard let opener = brackets.last, opener.active,
              let (target, end) = linkTail(after: pos + 1, text: String(chars[opener.textStart..<pos])) else {
            if !brackets.isEmpty { brackets.removeLast() }
            pending.append("]")
            pos += 1
            return
        }
        flush()
        let children = MarkdownInline.emphasized(Array(items[(opener.index + 1)...]))
        items.removeSubrange(opener.index...)
        items.append(.node(.link((opener.image ? "image:" : "link:") + target, children)))
        brackets.removeLast()
        if !opener.image {
            for index in brackets.indices where !brackets[index].image { brackets[index].active = false }
        }
        pos = end
    }

    /// linkTail resolves what follows a closing bracket: an inline destination, then a full, collapsed or shortcut
    /// reference. A full reference that is not defined falls back to nothing.
    private func linkTail(after start: Int, text: String) -> (String, Int)? {
        if start < chars.count, chars[start] == "(", let inline = inlineDestination(from: start + 1) { return inline }
        if let (label, end) = MarkdownScan.label(chars, from: start) {
            return definitions[MarkdownReference.normalized(label.isEmpty ? text : label)].map { ($0, end) }
        }
        return definitions[MarkdownReference.normalized(text)].map { ($0, start) }
    }

    private func inlineDestination(from start: Int) -> (String, Int)? {
        let destinationStart = MarkdownScan.skipWhitespace(chars, from: start)
        guard let (destination, afterDestination) = MarkdownScan.destination(chars, from: destinationStart) else { return nil }
        var index = MarkdownScan.skipWhitespace(chars, from: afterDestination)
        if index > afterDestination, let afterTitle = MarkdownScan.title(chars, from: index) {
            index = MarkdownScan.skipWhitespace(chars, from: afterTitle)
        }
        return index < chars.count && chars[index] == ")" ? (destination, index + 1) : nil
    }

    private mutating func angle() {
        if let (target, end) = autolink() {
            push(.link("link:" + target, [.text(target)]))
            pos = end
        } else if let end = MarkdownHTML.tagEnd(chars, from: pos) {
            push(.html(String(chars[pos..<end])))
            pos = end
        } else {
            pending.append("<")
            pos += 1
        }
    }

    /// autolink reads a `<scheme:…>` or `<user@host>` autolink at `pos`.
    private func autolink() -> (String, Int)? {
        guard let close = chars[pos...].dropFirst().firstIndex(where: { $0 == ">" || $0 == "<" || $0.isWhitespace }),
              chars[close] == ">" else { return nil }
        let body = String(chars[(pos + 1)..<close])
        return Self.isURI(body) || Self.isEmail(body) ? (body, close + 1) : nil
    }

    private static func isURI(_ body: String) -> Bool {
        let scheme = body.prefix { $0 != ":" }
        return (2...32).contains(scheme.count) && scheme.count < body.count && scheme.first?.isLetter == true
            && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
    }

    private static func isEmail(_ body: String) -> Bool {
        let parts = body.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".!#$%&'*+/=?^_`{|}~-".contains($0)) }) else {
            return false
        }
        return parts[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private mutating func entity() {
        if let (text, end) = MarkdownEntity.decode(chars, from: pos) {
            pending += text
            pos = end
        } else {
            pending.append("&")
            pos += 1
        }
    }
}
#endif
