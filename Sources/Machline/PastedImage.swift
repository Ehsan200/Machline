import AppKit
import SwiftUI

/// A pasted image reaches the transcript as text: the CLI writes `[Image: source: /path.png]` and
/// keeps the file on disk rather than inlining the bytes. Printed verbatim that line hides the one
/// thing worth seeing, so the message body is split into prose and image references, and the
/// references are drawn as the picture that was actually sent.
struct MessageBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ForEach(MessageSegment.parse(text)) { segment in
                switch segment.content {
                case .prose(let body):
                    Text(body)
                        .font(Theme.Typography.prose)
                        .fontWeight(.medium)
                        .lineSpacing(Theme.Typography.proseLineSpacing)
                        .foregroundStyle(Theme.Colors.textStrong)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .image(let url):
                    PastedImageView(url: url)
                }
            }
        }
    }
}

/// One run of a message: either prose or a reference to an image file on disk.
struct MessageSegment: Identifiable {
    enum Content {
        case prose(String)
        case image(URL)
    }

    let id: Int
    let content: Content

    /// Matches the CLI's own rendering of an attachment. The path runs to the closing bracket;
    /// screenshot names contain spaces, so the capture is deliberately greedy about everything but
    /// `]`.
    /// Rebuilt per call: `Regex` is not `Sendable`, so it cannot be a stored static under strict
    /// concurrency, and compiling one literal per message is nothing next to decoding the images.
    private static var reference: Regex<(Substring, Substring)> {
        /\[Image: source: ([^\]]+)\]/
    }

    /// An image the operator named themselves, rather than one the CLI attached.
    ///
    /// Dragging a screenshot into the composer inserts `@/absolute/path.png`, which the CLI reads
    /// but never rewrites into an `[Image: source:]` line — so the turn showed a path where the
    /// picture should be. The mention is replaced by the picture, not annotated with it: a path and
    /// its own contents side by side is the same attachment said twice, and the long one is the
    /// half nobody reads.
    ///
    /// Deliberately narrow. Absolute paths only, ending in a known image extension at a word
    /// boundary — a screenshot name carries spaces (`Screenshot 2026-08-22 at 9.45.42 PM.png`), so
    /// the path cannot simply run to the next space, and the extension is what ends it instead.
    private static var mentionedImage: Regex<(Substring, Substring)> {
        /@?(\/[^\n]*?\.(?i:png|jpe?g|gif|webp|heic|heif|bmp|tiff?))(?=[\s,;)\]]|$)/
    }

    /// One image reference found in the text, and the span it occupies.
    private struct Reference {
        let range: Range<String.Index>
        let path: String
    }

    static func parse(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var cursor = text.startIndex
        var seen: Set<String> = []

        func appendProse(_ range: Range<String.Index>) {
            let body = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            segments.append(.init(id: segments.count, content: .prose(body)))
        }

        for reference in references(in: text) {
            guard seen.insert(reference.path).inserted else { continue }
            appendProse(cursor..<reference.range.lowerBound)
            segments.append(.init(
                id: segments.count,
                content: .image(URL(fileURLWithPath: reference.path))))
            cursor = reference.range.upperBound
        }
        appendProse(cursor..<text.endIndex)

        // A message that is nothing but whitespace still has to occupy a row, or the bubble
        // collapses to its padding and reads as a rendering fault.
        if segments.isEmpty {
            segments.append(.init(id: 0, content: .prose(text)))
        }
        return segments
    }

    /// Every image reference in the text, in the order it appears.
    ///
    /// A bare path inside an `[Image: source: …]` marker matches both patterns, so the markers win
    /// any overlap: they are the CLI's own rendering, and the whole marker is what has to go rather
    /// than the path within it.
    private static func references(in text: String) -> [Reference] {
        var found = text.matches(of: reference).map {
            Reference(
                range: $0.range,
                path: String($0.output.1).trimmingCharacters(in: .whitespaces))
        }

        for match in text.matches(of: mentionedImage) {
            guard !found.contains(where: { $0.range.overlaps(match.range) }) else { continue }
            let path = String(match.output.1).trimmingCharacters(in: .whitespaces)
            // An attachment the CLI recorded really was sent, so a marker with nothing behind it
            // still earns the missing-image notice. A path the operator merely typed is prose that
            // happens to end in `.png` — claiming an image went missing there would be an
            // invention, so it is left as the prose it is.
            guard FileManager.default.fileExists(atPath: path) else { continue }
            found.append(Reference(range: match.range, path: path))
        }

        return found
            .filter { !$0.path.isEmpty }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

/// The image itself, capped so a full-screen grab does not push the rest of the turn off screen.
/// Clicking opens the original at full size in the system viewer.
private struct PastedImageView: View {
    let url: URL

    @State private var image: NSImage?
    @State private var hasLoaded = false
    @State private var isHovering = false

    /// Distinguishes the two ways a reference goes bad, because the answers differ: a reaped
    /// temporary file is gone for good, while an unreadable one that is still there is worth
    /// opening by hand.
    private var unreadableReason: String {
        FileManager.default.fileExists(atPath: url.path)
            ? "Image could not be read"
            : "Image no longer on disk"
    }

    var body: some View {
        Group {
            if let image {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 460, maxHeight: 300, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Layout.radius)
                                .strokeBorder(
                                    isHovering ? Theme.Colors.muted : Theme.Colors.border,
                                    lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .help("Open \(url.lastPathComponent)")
            } else if hasLoaded {
                // Screenshots are pasted from a temporary directory the system reaps, so a
                // reference outliving its file is ordinary rather than a fault. Say so outright —
                // a silent gap would read as the transcript having lost the attachment.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(Theme.Colors.warning)
                        Text(unreadableReason)
                            .foregroundStyle(Theme.Colors.text)
                    }
                    Text(url.path)
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(Theme.Typography.meta)
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, Theme.Space.xs)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Layout.radius)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1))
                .help(url.path)
            } else {
                // Nothing is claimed about the file until the decode has actually run, so a slow
                // read never flashes a "gone" notice at an image that is about to appear.
                Text(url.lastPathComponent)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Decoding happens off the first render so a long transcript of screenshots does not stall
        // the scroll, and `id` re-runs it if the row is recycled onto another attachment.
        .task(id: url) {
            hasLoaded = false
            let path = url.path
            image = await Task.detached(priority: .utility) { NSImage(contentsOfFile: path) }.value
            hasLoaded = true
        }
    }
}
