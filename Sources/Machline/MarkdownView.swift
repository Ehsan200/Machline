import SwiftUI

/// Agent prose, rendered as Markdown.
///
/// `AttributedString(markdown:)` alone is not enough: it handles inline spans but flattens block
/// structure, so headings, lists, fenced code, and tables come out as one paragraph with the
/// syntax still visible. So blocks are parsed here and inline spans are handed to Foundation.
enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case ordered([String])
    case code(language: String?, text: String)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])
}

enum MarkdownParser {

    /// Parsed blocks, keyed by source.
    ///
    /// SwiftUI rebuilds a view's body on any observable change, so an uncached parse runs for every
    /// message on every frame — and while a reply streams, that is dozens of times a second over
    /// text that grows each time.
    @MainActor private static let cache: NSCache<NSString, BlockBox> = {
        let cache = NSCache<NSString, BlockBox>()
        // `NSCache` evicts on memory pressure, which is a warning the system raises late and a
        // long-lived window would rather not wait for. Held to a few megabytes of source instead.
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    @MainActor private final class BlockBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    /// Parses `markdown`, reusing an earlier parse of the same source.
    ///
    /// `storing` is false for text that is still being streamed. Every frame of a reply is a
    /// slightly longer prefix of the last, so each is a distinct key that will never be asked for
    /// again — caching them filled the cache with hundreds of dead prefixes of a message whose
    /// final form is the only one worth keeping.
    @MainActor
    static func cachedBlocks(in markdown: String, storing: Bool = true) -> [MarkdownBlock] {
        let key = markdown as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let parsed = blocks(in: markdown)
        // Cost is the source length, so one enormous reply cannot hold the whole cache hostage.
        if storing { cache.setObject(BlockBox(parsed), forKey: key, cost: markdown.utf8.count) }
        return parsed
    }

    static func blocks(in markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code. The fence is consumed to its closing pair, or to the end of the text —
            // a stream still being written often has no closing fence yet.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                var body: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1  // closing fence
                blocks.append(.code(
                    language: language.isEmpty ? nil : language,
                    text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let level = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(
                    level: level,
                    text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                var body: [String] = []
                while index < lines.count {
                    let quoted = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoted.hasPrefix(">") else { break }
                    body.append(String(quoted.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(body.joined(separator: "\n")))
                continue
            }

            // A table needs its separator row (`| --- |`) to be a table rather than two lines that
            // happen to contain pipes.
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let header = cells(in: trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    rows.append(cells(in: row))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isBullet(item) else { break }
                    items.append(String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.bullets(items))
                continue
            }

            if orderedMarker(trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let marker = orderedMarker(item) else { break }
                    items.append(String(item.dropFirst(marker)).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.ordered(items))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    /// The width of an ordered-list marker (`1. `), or `nil` when the line is not one.
    private static func orderedMarker(_ line: String) -> Int? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return digits.count + 2
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") else { return false }
        let body = line.filter { !" |".contains($0) }
        return !body.isEmpty && body.allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func cells(in row: String) -> [String] {
        let pieces: [String] = row
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // A leading and trailing pipe produce empty edge pieces that are not cells.
        guard pieces.count > 2 else { return pieces }
        return Array(pieces.dropFirst().dropLast())
    }
}

// MARK: - View

extension MarkdownBlock {
    /// Prose blocks flow together in one selectable run; code and tables keep their own frame.
    var isProse: Bool {
        switch self {
        case .code, .table: return false
        default: return true
        }
    }
}

struct MarkdownView: View {
    let markdown: String
    var textColor: Color = Theme.Colors.text
    /// A plain reference, not `@Bindable`: nothing here reads a property off it. `nil` renders
    /// without the quote control.
    var model: AppModel?
    /// Set for a reply that is still arriving. Each frame of one is a slightly longer prefix of
    /// the last and is never rendered twice, so nothing about it is worth caching — and caching it
    /// anyway evicts the finished replies that are.
    var isStreaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            ForEach(runs) { run in
                switch run.kind {
                case .prose(let blocks):
                    MarkdownProse(blocks: blocks, textColor: textColor, storing: !isStreaming)
                case .code(let language, let text):
                    CodeBlock(language: language, text: text, model: model)
                case .table(let header, let rows):
                    MarkdownTable(header: header, rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Consecutive prose blocks are merged into one run.
    ///
    /// This is what makes a selection drag across paragraphs, list items, and headings: SwiftUI
    /// selection lives inside a single `Text`, so a message rendered as one view per block can only
    /// ever be copied one block at a time.
    private var runs: [MarkdownRun] {
        var runs: [MarkdownRun] = []
        var prose: [MarkdownBlock] = []

        func flush() {
            guard !prose.isEmpty else { return }
            runs.append(MarkdownRun(index: runs.count, kind: .prose(prose)))
            prose.removeAll()
        }

        for block in MarkdownParser.cachedBlocks(in: markdown, storing: !isStreaming) {
            if block.isProse {
                prose.append(block)
                continue
            }
            flush()
            switch block {
            case .code(let language, let text):
                runs.append(MarkdownRun(index: runs.count, kind: .code(language, text)))
            case .table(let header, let rows):
                runs.append(MarkdownRun(index: runs.count, kind: .table(header, rows)))
            default:
                break
            }
        }
        flush()
        return runs
    }
}

struct MarkdownRun: Identifiable {
    enum Kind {
        case prose([MarkdownBlock])
        case code(String?, String)
        case table([String], [[String]])
    }

    let index: Int
    let kind: Kind
    var id: Int { index }
}

/// Rendered prose, keyed by the blocks it came from.
///
/// Parsing the source into blocks was already cached; building the `AttributedString` from them
/// was not, and that is the expensive half — a `Text(markdown:)` parse per line, plus paragraph
/// styles and per-run attribute passes. SwiftUI rebuilds a body on any observable change, so a
/// transcript of forty replies rebuilt forty attributed strings on every frame of a stream, and on
/// every click that changed anything at all. That is the lag on interacting with a long output.
///
/// Keyed on the blocks themselves rather than on a digest: `MarkdownBlock` is `Hashable`, so this
/// is a real equality check and cannot return the wrong text for a colliding key.
@MainActor
enum ProseCache {
    private struct Key: Hashable {
        let blocks: [MarkdownBlock]
        let color: Color
    }

    /// Bounded, and evicted oldest-first. A long-running window otherwise accumulates every reply
    /// it has ever rendered.
    private static let limit = 400
    private static var storage: [Key: AttributedString] = [:]
    private static var insertionOrder: [Key] = []

    /// `storing` is false for a reply that is still arriving: each frame of one is a distinct key
    /// that will never be looked up again, so storing them walks the whole window's worth of
    /// finished replies out of a 400-entry cache over the course of a single long message.
    static func attributed(
        for blocks: [MarkdownBlock], color: Color, storing: Bool = true,
        build: () -> AttributedString
    ) -> AttributedString {
        let key = Key(blocks: blocks, color: color)
        if let hit = storage[key] { return hit }

        let made = build()
        guard storing else { return made }
        storage[key] = made
        insertionOrder.append(key)
        if insertionOrder.count > limit {
            let evicted = insertionOrder.removeFirst()
            storage[evicted] = nil
        }
        return made
    }
}

/// A run of prose as a single selectable `Text`.
///
/// Structure survives as attributes and paragraph styles rather than as separate views, so a
/// heading still reads as a heading and a list still hangs its indent — but the whole run is one
/// selection.
struct MarkdownProse: View {
    let blocks: [MarkdownBlock]
    let textColor: Color
    var storing = true

    var body: some View {
        Text(ProseCache.attributed(for: blocks, color: textColor, storing: storing) { build() })
            .lineSpacing(Theme.Typography.proseLineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func build() -> AttributedString {
        var output = AttributedString()

        for (index, block) in blocks.enumerated() {
            if index > 0 { output.append(AttributedString("\n\n")) }

            switch block {
            case .heading(let level, let text):
                var piece = inline(text, color: Theme.Colors.textStrong)
                piece.font = .system(size: headingSize(level), weight: .semibold)
                output.append(piece)

            case .paragraph(let text):
                output.append(inline(text, color: textColor))

            case .bullets(let items):
                output.append(list(items) { _ in "•" })

            case .ordered(let items):
                output.append(list(items) { "\($0 + 1)." })

            case .quote(let text):
                output.append(inline(text, color: Theme.Colors.muted))

            case .rule:
                var piece = AttributedString("────────")
                piece.foregroundColor = Theme.Colors.border
                output.append(piece)

            case .code, .table:
                break  // Rendered as their own views.
            }
        }
        return output
    }

    /// A marker and its item, joined by a no-break space so the two never land on separate lines.
    ///
    /// No hanging indent: a wrapped item returns to the margin. SwiftUI's `Text` drops the AppKit
    /// paragraph-style attribute entirely — `headIndent` and `tabStops` were both silently ignored,
    /// which is what made the tab render at the default stop and throw the marker away from its
    /// text. Hanging it properly means one view per item, and that costs the single-`Text` selection
    /// this whole type exists to preserve.
    private func list(
        _ items: [String], marker: (Int) -> String
    ) -> AttributedString {
        var output = AttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 { output.append(AttributedString("\n")) }

            var bullet = AttributedString("\(marker(index))\u{00A0}")
            bullet.foregroundColor = Theme.Colors.accent
            bullet.font = Theme.Typography.prose

            output.append(bullet)
            output.append(inline(item, color: textColor))
        }
        return output
    }

    private func inline(_ source: String, color: Color) -> AttributedString {
        // `.inlineOnlyPreservingWhitespace` keeps a soft-wrapped paragraph intact; the full parser
        // would swallow newlines and the block syntax already handled upstream.
        guard var string = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else {
            var fallback = AttributedString(source)
            fallback.foregroundColor = color
            fallback.font = Theme.Typography.prose
            return fallback
        }

        string.foregroundColor = color
        string.font = Theme.Typography.prose
        // Foundation gives inline code the surrounding face, at which point it stops reading as
        // code at all.
        for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true {
            string[run.range].font = Theme.Typography.mono
            string[run.range].foregroundColor = Theme.Colors.code
        }
        for run in string.runs where run.link != nil {
            string[run.range].foregroundColor = Theme.Colors.link
            string[run.range].underlineStyle = .single
        }
        return string
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 21
        case 2: return 18
        case 3: return 16
        default: return 15
        }
    }
}

/// A fenced code block. Never wrapped — alignment in code is meaningful — so it scrolls sideways.
struct CodeBlock: View {
    let language: String?
    let text: String
    var model: AppModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                }
                Spacer(minLength: 0)
                if let model {
                    QuoteButton(
                        model: model, text: text, source: .code(language: language),
                        help: "Quote this block in your next message")
                }
                CopyButton(text: text, help: "Copy this block")
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 3)
            Hairline(color: Theme.Colors.border.opacity(0.6))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(text)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Colors.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Layout.hairline))
    }
}

struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                CopyButton(text: tabSeparated, help: "Copy as tab-separated text")
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 3)
            Hairline(color: Theme.Colors.border.opacity(0.6))

            ScrollView(.horizontal, showsIndicators: true) {
                // Measured once for the table rather than once per row, which was quadratic in
                // the number of rows.
                let widths = columnWidths
                VStack(alignment: .leading, spacing: 0) {
                    // A table whose header cells are all blank has no header to draw; rendering it
                    // leaves an empty band above the data.
                    if header.contains(where: { !$0.isEmpty }) {
                        row(header, widths: widths, isHeader: true)
                        Hairline(color: Theme.Colors.border)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                        if index > 0 {
                            Hairline(color: Theme.Colors.border.opacity(0.4))
                        }
                        row(cells, widths: widths, isHeader: false)
                    }
                }
            }
        }
        .background(Theme.Colors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                .strokeBorder(Theme.Colors.border, lineWidth: Theme.Layout.hairline))
    }

    /// Tab-separated, so it pastes into a spreadsheet as columns rather than as one cell.
    private var tabSeparated: String {
        ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    /// Column widths are shared across the whole table and sized to content.
    ///
    /// A fixed width wraps a path in a narrow column while leaving a one-word column mostly empty.
    /// The estimate is character-count based — text measurement per cell would mean laying the
    /// table out twice — and clamped so one long cell cannot push the rest off screen.
    private var columnWidths: [CGFloat] {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return [] }

        return (0..<columnCount).map { column in
            let longest = ([header] + rows)
                .compactMap { $0.indices.contains(column) ? $0[column] : nil }
                .map { MarkdownTable.displayLength($0) }
                .max() ?? 0
            return min(360, max(90, CGFloat(longest) * 7.6 + 24))
        }
    }

    /// The width the cell will actually occupy — Markdown punctuation is not drawn.
    private static func displayLength(_ cell: String) -> Int {
        cell.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .count
    }

    private func row(_ cells: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.Colors.border.opacity(0.4))
                        .frame(width: Theme.Layout.hairline)
                }
                // Inline markdown, so a cell holding `a/path` or **bold** reads as one.
                MarkdownInline(
                    cell,
                    color: isHeader ? Theme.Colors.textStrong : Theme.Colors.text,
                    font: isHeader ? Theme.Typography.controlMedium : Theme.Typography.control)
                    .frame(
                        width: widths.indices.contains(index) ? widths[index] : 150,
                        alignment: .leading)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 6)
            }
        }
    }
}

/// Copies text to the pasteboard, confirming that it did.
///
/// Selection handles reading; this handles taking. A long command, a code block, or a whole reply
/// is not worth dragging across.
struct CopyButton: View {
    let text: String
    var help: String = "Copy"

    @State private var hasCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hasCopied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                hasCopied = false
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .medium))
                if hasCopied {
                    Text("copied")
                        .font(Theme.Typography.meta)
                }
            }
            .foregroundStyle(hasCopied ? Theme.Colors.success : Theme.Colors.subtle)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// One span of inline Markdown — bold, italic, links, inline code — as a single selectable `Text`.
///
/// Prose goes through `MarkdownProse`, which merges whole blocks into one selection. This is for
/// the places that are genuinely one short span on their own, like a table cell.
struct MarkdownInline: View {
    let source: String
    let color: Color
    let font: Font

    init(_ source: String, color: Color, font: Font = Theme.Typography.prose) {
        self.source = source
        self.color = color
        self.font = font
    }

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        guard var string = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else {
            var fallback = AttributedString(source)
            fallback.foregroundColor = color
            fallback.font = font
            return fallback
        }

        string.foregroundColor = color
        string.font = font
        // Foundation gives inline code the surrounding face, at which point it stops reading as
        // code at all.
        for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true {
            string[run.range].font = Theme.Typography.monoSmall
            string[run.range].foregroundColor = Theme.Colors.code
        }
        for run in string.runs where run.link != nil {
            string[run.range].foregroundColor = Theme.Colors.link
            string[run.range].underlineStyle = .single
        }
        return string
    }
}
