import Foundation

/// A span of source that should be coloured.
public struct SyntaxSpan: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case comment
        case string
        case keyword
        case number
        case type
        case plain
    }

    public let range: Range<String.Index>
    public let kind: Kind
}

/// What a language looks like, to the scanner.
public struct SyntaxRules: Sendable {
    public let lineComments: [String]
    /// Opening and closing delimiters, e.g. `("/*", "*/")`.
    public let blockComments: [(open: String, close: String)]
    /// Quote characters that start a string. Escapes are honoured with `\`.
    public let stringDelimiters: Set<Character>
    public let keywords: Set<String>
    /// Whether an identifier starting with a capital is a type. True for languages that hold to
    /// the convention; false where it would colour ordinary variables.
    public let capitalisedIdentifiersAreTypes: Bool

    public init(
        lineComments: [String],
        blockComments: [(open: String, close: String)] = [],
        stringDelimiters: Set<Character> = ["\"", "'"],
        keywords: Set<String>,
        capitalisedIdentifiersAreTypes: Bool = false
    ) {
        self.lineComments = lineComments
        self.blockComments = blockComments
        self.stringDelimiters = stringDelimiters
        self.keywords = keywords
        self.capitalisedIdentifiersAreTypes = capitalisedIdentifiersAreTypes
    }
}

/// Colours source code well enough to read.
///
/// A hand-written scanner rather than a pile of regular expressions: a regex for strings cannot
/// know it is inside a comment, and one for comments cannot know it is inside a string, so the two
/// disagree on exactly the lines where it matters. One left-to-right pass has no such ambiguity.
///
/// This is *not* a parser. It knows nothing about scope, types, or imports, and it will colour a
/// keyword used as a field name. That is the deliberate ceiling: a real one means tree-sitter, and
/// this is here so reading a file does not require it.
public enum SyntaxHighlighter {

    public static func spans(in source: String, rules: SyntaxRules) -> [SyntaxSpan] {
        spans(in: source[...], rules: rules)
    }

    /// Scans one region.
    ///
    /// Takes a `Substring` because a substring shares its base string's indices: a region scanned
    /// this way returns ranges that are already valid against the whole file, with no offset
    /// arithmetic to get wrong.
    public static func spans(in source: Substring, rules: SyntaxRules) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var index = source.startIndex

        func rest(from position: String.Index) -> Substring { source[position...] }
        let endOfRegion = source.endIndex

        while index < source.endIndex {
            let character = source[index]

            // Comments first: everything inside one is a comment, whatever it looks like.
            if let marker = rules.lineComments.first(where: { rest(from: index).hasPrefix($0) }) {
                _ = marker
                let end = source[index...].firstIndex(of: "\n") ?? source.endIndex
                spans.append(SyntaxSpan(range: index..<end, kind: .comment))
                index = end
                continue
            }

            if let pair = rules.blockComments.first(where: { rest(from: index).hasPrefix($0.open) }) {
                let afterOpen = source.index(
                    index, offsetBy: pair.open.count, limitedBy: endOfRegion) ?? endOfRegion
                let end = source.range(of: pair.close, range: afterOpen..<endOfRegion)?.upperBound
                    ?? endOfRegion
                spans.append(SyntaxSpan(range: index..<end, kind: .comment))
                index = end
                continue
            }

            if rules.stringDelimiters.contains(character) {
                let end = endOfString(in: source, from: index, quote: character)
                spans.append(SyntaxSpan(range: index..<end, kind: .string))
                index = end
                continue
            }

            if character.isNumber, isTokenStart(source, index) {
                var end = index
                while end < source.endIndex,
                      source[end].isHexDigit || source[end] == "." || source[end] == "_"
                        || source[end] == "x" || source[end] == "o" || source[end] == "b" {
                    end = source.index(after: end)
                }
                spans.append(SyntaxSpan(range: index..<end, kind: .number))
                index = end
                continue
            }

            if character.isLetter || character == "_" || character == "@" || character == "#" {
                var end = index
                while end < source.endIndex,
                      source[end].isLetter || source[end].isNumber || source[end] == "_"
                        || source[end] == "@" || source[end] == "#" {
                    end = source.index(after: end)
                }
                let word = String(source[index..<end])
                let bare = word.drop { $0 == "@" || $0 == "#" }

                if rules.keywords.contains(word) || rules.keywords.contains(String(bare)) {
                    spans.append(SyntaxSpan(range: index..<end, kind: .keyword))
                } else if rules.capitalisedIdentifiersAreTypes,
                          let first = bare.first, first.isUppercase {
                    spans.append(SyntaxSpan(range: index..<end, kind: .type))
                }
                index = end
                continue
            }

            index = source.index(after: index)
        }
        return spans
    }

    /// Where a string literal ends, honouring backslash escapes. An unterminated literal runs to
    /// the end of its line rather than swallowing the rest of the file.
    private static func endOfString(
        in source: Substring, from start: String.Index, quote: Character
    ) -> String.Index {
        var index = source.index(after: start)
        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                index = source.index(index, offsetBy: 2, limitedBy: source.endIndex)
                    ?? source.endIndex
                continue
            }
            if character == quote { return source.index(after: index) }
            if character == "\n" { return index }
            index = source.index(after: index)
        }
        return source.endIndex
    }

    /// A digit inside an identifier is not a number literal.
    private static func isTokenStart(_ source: Substring, _ index: String.Index) -> Bool {
        guard index > source.startIndex else { return true }
        let previous = source[source.index(before: index)]
        return !(previous.isLetter || previous.isNumber || previous == "_")
    }

    // MARK: - Languages

    /// Rules for a filename, or `nil` when the language is unknown and the file should be shown
    /// plain rather than coloured by guesswork.
    public static func rules(forFile name: String) -> SyntaxRules? {
        let lowered = name.lowercased()
        let ext = lowered.split(separator: ".").dropFirst().last.map(String.init) ?? ""

        switch ext {
        case "swift": return .swift
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return .javascript
        case "json": return .json
        case "py": return .python
        case "rs": return .rust
        case "go": return .go
        case "rb": return .ruby
        case "sh", "bash", "zsh", "fish": return .shell
        case "c", "h", "cpp", "hpp", "cc", "m", "mm": return .cFamily
        case "java", "kt", "kts": return .jvm
        case "css", "scss", "less": return .css
        case "yml", "yaml", "toml": return .configuration
        default:
            return lowered == "makefile" || lowered == "dockerfile" ? .shell : nil
        }
    }
}

extension SyntaxRules {
    public static let swift = SyntaxRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        stringDelimiters: ["\""],
        keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
            "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
            "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
            "init", "inout", "internal", "is", "let", "nil", "nonisolated", "open", "operator",
            "private", "protocol", "public", "repeat", "return", "self", "some", "static",
            "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
            "var", "where", "while", "@MainActor", "@Observable", "@escaping", "@Sendable"
        ],
        capitalisedIdentifiersAreTypes: true)

    public static let javascript = SyntaxRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'", "`"],
        keywords: [
            "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
            "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
            "from", "function", "if", "implements", "import", "in", "instanceof", "interface",
            "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw",
            "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"
        ],
        capitalisedIdentifiersAreTypes: true)

    public static let json = SyntaxRules(
        lineComments: [], stringDelimiters: ["\""],
        keywords: ["true", "false", "null"])

    public static let python = SyntaxRules(
        lineComments: ["#"], stringDelimiters: ["\"", "'"],
        keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
            "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
            "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
            "True", "try", "while", "with", "yield"
        ])

    public static let rust = SyntaxRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        stringDelimiters: ["\""],
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
            "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
            "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
            "trait", "true", "type", "unsafe", "use", "where", "while"
        ],
        capitalisedIdentifiersAreTypes: true)

    public static let go = SyntaxRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "`"],
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
            "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
            "return", "select", "struct", "switch", "type", "var", "nil", "true", "false"
        ])

    public static let ruby = SyntaxRules(
        lineComments: ["#"], stringDelimiters: ["\"", "'"],
        keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end",
            "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
            "rescue", "retry", "return", "self", "super", "then", "true", "unless", "until", "when",
            "while", "yield"
        ])

    public static let shell = SyntaxRules(
        lineComments: ["#"], stringDelimiters: ["\"", "'"],
        keywords: [
            "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if",
            "in", "local", "return", "set", "then", "until", "while", "echo", "cd", "source"
        ])

    public static let cFamily = SyntaxRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        keywords: [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
            "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
            "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
            "union", "unsigned", "void", "volatile", "while", "#include", "#define", "#if",
            "#endif", "class", "namespace", "public", "private", "protected", "template", "using"
        ])

    public static let jvm = SyntaxRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        keywords: [
            "abstract", "as", "break", "case", "catch", "class", "companion", "const", "continue",
            "data", "do", "else", "enum", "extends", "false", "final", "finally", "for", "fun",
            "if", "implements", "import", "in", "interface", "internal", "is", "it", "lateinit",
            "new", "null", "object", "open", "override", "package", "private", "protected",
            "public", "return", "sealed", "static", "super", "suspend", "this", "throw", "throws",
            "true", "try", "val", "var", "void", "when", "while"
        ],
        capitalisedIdentifiersAreTypes: true)

    public static let css = SyntaxRules(
        lineComments: ["//"], blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        keywords: ["@media", "@import", "@keyframes", "@supports", "!important", "from", "to"])

    public static let configuration = SyntaxRules(
        lineComments: ["#"], stringDelimiters: ["\"", "'"],
        keywords: ["true", "false", "null", "yes", "no", "on", "off"])
}

// MARK: - Composite files

extension SyntaxHighlighter {

    /// A single-file component: markup with `<script>` and `<style>` blocks inside it.
    ///
    /// Highlighting one of these with a single ruleset is wrong whichever one is picked — the
    /// script block would have its `//` comments treated as text, or the template's `<!-- -->`
    /// would go uncoloured. So each region is scanned with the language it actually holds.
    static let compositeExtensions: Set<String> = ["vue", "svelte", "html", "htm", "astro"]

    /// Spans for a file, choosing between the simple and composite paths.
    public static func spans(in source: String, fileName: String) -> [SyntaxSpan] {
        let ext = fileName.lowercased().split(separator: ".").dropFirst().last.map(String.init) ?? ""
        if compositeExtensions.contains(ext) {
            return compositeSpans(in: source)
        }
        guard let rules = rules(forFile: fileName) else { return [] }
        return spans(in: source, rules: rules)
    }

    /// True when the file will be coloured at all, so the interface can say when it will not.
    public static func canHighlight(fileName: String) -> Bool {
        let ext = fileName.lowercased().split(separator: ".").dropFirst().last.map(String.init) ?? ""
        return compositeExtensions.contains(ext) || rules(forFile: fileName) != nil
    }

    private static func compositeSpans(in source: String) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var cursor = source.startIndex

        for region in embeddedRegions(in: source) {
            // Markup between the embedded blocks.
            if cursor < region.range.lowerBound {
                spans += self.spans(in: source[cursor..<region.range.lowerBound], rules: .markup)
            }
            spans += self.spans(in: source[region.range], rules: region.rules)
            cursor = region.range.upperBound
        }

        if cursor < source.endIndex {
            spans += self.spans(in: source[cursor...], rules: .markup)
        }
        return spans
    }

    private struct EmbeddedRegion {
        let range: Range<String.Index>
        let rules: SyntaxRules
    }

    /// The bodies of `<script>` and `<style>` blocks, in order.
    ///
    /// Only the content between the tags is claimed; the tags themselves stay markup, so they are
    /// coloured like the rest of the template.
    private static func embeddedRegions(in source: String) -> [EmbeddedRegion] {
        var regions: [EmbeddedRegion] = []

        for (tag, rules) in [("script", SyntaxRules.javascript), ("style", SyntaxRules.css)] {
            var searchFrom = source.startIndex
            while let open = source.range(
                of: "<\(tag)", options: [.caseInsensitive], range: searchFrom..<source.endIndex) {
                // The opening tag may carry attributes — `<script setup lang="ts">`.
                guard let openEnd = source[open.upperBound...].firstIndex(of: ">") else { break }
                let bodyStart = source.index(after: openEnd)
                guard let close = source.range(
                    of: "</\(tag)", options: [.caseInsensitive],
                    range: bodyStart..<source.endIndex)
                else { break }

                regions.append(EmbeddedRegion(range: bodyStart..<close.lowerBound, rules: rules))
                searchFrom = close.upperBound
            }
        }

        return regions.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

extension SyntaxRules {
    /// Markup: comments and attribute strings. Tag names are left alone rather than guessed at —
    /// a component tag is not a keyword, and colouring it as one is worse than not colouring it.
    public static let markup = SyntaxRules(
        lineComments: [], blockComments: [("<!--", "-->")],
        stringDelimiters: ["\"", "'"],
        keywords: [])
}
