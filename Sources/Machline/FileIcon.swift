import SwiftUI

/// A glyph and colour for a filename, in the spirit of Atom's file icons.
///
/// The glyphs are SF Symbols rather than the Atom icon font: shipping that set means bundling a
/// font and its licence, and the value here is the *colour coding* — telling Swift from JSON from
/// a lockfile at a glance — which carries fine without the exact glyphs.
enum FileIcon {

    struct Style {
        let symbol: String
        let color: Color
    }

    static func style(for path: String) -> Style {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let lowered = name.lowercased()

        // Whole-name matches first: a lockfile or a Dockerfile is not identified by its extension.
        if let style = byName[lowered] { return style }
        if lowered.hasPrefix("dockerfile") { return Style(symbol: "shippingbox", color: docker) }
        if lowered.hasPrefix(".env") { return Style(symbol: "key", color: config) }

        let ext = lowered.split(separator: ".").dropFirst().last.map(String.init) ?? ""
        return byExtension[ext] ?? Style(symbol: "doc", color: Theme.Colors.muted)
    }

    static func directoryStyle() -> Style {
        Style(symbol: "folder.fill", color: Theme.Colors.info)
    }

    // Palette, kept close to the language colours a file-icon theme uses.
    private static let swift = Color(hex: 0xF0_5138)
    private static let script = Color(hex: 0xF1_E05A)
    private static let types = Color(hex: 0x3178_C6)
    private static let markup = Color(hex: 0xE3_4C26)
    private static let style = Color(hex: 0x56_3D7C)
    private static let data = Color(hex: 0xCB_CB41)
    private static let docs = Color(hex: 0x9C_A3AF)
    private static let shell = Color(hex: 0x89_E051)
    private static let rust = Color(hex: 0xDE_A584)
    private static let go = Color(hex: 0x00_ADD8)
    private static let python = Color(hex: 0x3572_A5)
    private static let ruby = Color(hex: 0x70_1516)
    private static let config = Color(hex: 0xA0_74C4)
    private static let docker = Color(hex: 0x2496_ED)
    private static let media = Color(hex: 0xA0_74C4)

    private static let byName: [String: Style] = [
        "package.json": Style(symbol: "shippingbox", color: data),
        "package-lock.json": Style(symbol: "lock.doc", color: docs),
        "package.swift": Style(symbol: "shippingbox", color: swift),
        "cargo.toml": Style(symbol: "shippingbox", color: rust),
        "cargo.lock": Style(symbol: "lock.doc", color: docs),
        "go.mod": Style(symbol: "shippingbox", color: go),
        "gemfile": Style(symbol: "shippingbox", color: ruby),
        "makefile": Style(symbol: "hammer", color: config),
        "readme.md": Style(symbol: "book", color: docs),
        "claude.md": Style(symbol: "brain", color: Theme.Colors.accent),
        "license": Style(symbol: "scroll", color: docs),
        ".gitignore": Style(symbol: "eye.slash", color: markup),
        ".gitattributes": Style(symbol: "gearshape", color: markup)
    ]

    private static let byExtension: [String: Style] = [
        "swift": Style(symbol: "swift", color: swift),
        "ts": Style(symbol: "curlybraces", color: types),
        "tsx": Style(symbol: "curlybraces", color: types),
        "js": Style(symbol: "curlybraces", color: script),
        "jsx": Style(symbol: "curlybraces", color: script),
        "mjs": Style(symbol: "curlybraces", color: script),
        "json": Style(symbol: "curlybraces.square", color: data),
        "yml": Style(symbol: "list.bullet.indent", color: config),
        "yaml": Style(symbol: "list.bullet.indent", color: config),
        "toml": Style(symbol: "list.bullet.indent", color: config),
        "md": Style(symbol: "text.alignleft", color: docs),
        "txt": Style(symbol: "doc.text", color: docs),
        "sh": Style(symbol: "terminal", color: shell),
        "bash": Style(symbol: "terminal", color: shell),
        "fish": Style(symbol: "terminal", color: shell),
        "zsh": Style(symbol: "terminal", color: shell),
        "py": Style(symbol: "chevron.left.forwardslash.chevron.right", color: python),
        "rs": Style(symbol: "gearshape.2", color: rust),
        "go": Style(symbol: "chevron.left.forwardslash.chevron.right", color: go),
        "rb": Style(symbol: "diamond", color: ruby),
        "html": Style(symbol: "chevron.left.slash.chevron.right", color: markup),
        "css": Style(symbol: "paintbrush", color: style),
        "scss": Style(symbol: "paintbrush", color: style),
        "vue": Style(symbol: "chevron.left.slash.chevron.right", color: shell),
        "png": Style(symbol: "photo", color: media),
        "jpg": Style(symbol: "photo", color: media),
        "jpeg": Style(symbol: "photo", color: media),
        "svg": Style(symbol: "photo.artframe", color: media),
        "pdf": Style(symbol: "doc.richtext", color: markup),
        "lock": Style(symbol: "lock.doc", color: docs),
        "plist": Style(symbol: "list.bullet.rectangle", color: config),
        "sql": Style(symbol: "cylinder", color: data),
        "patch": Style(symbol: "plusminus", color: docs),
        "diff": Style(symbol: "plusminus", color: docs)
    ]
}

/// The icon shown beside a path.
struct FileIconView: View {
    let path: String
    var isDirectory = false
    var size: CGFloat = 11

    var body: some View {
        let style = isDirectory ? FileIcon.directoryStyle() : FileIcon.style(for: path)
        return Image(systemName: style.symbol)
            .font(.system(size: size))
            .foregroundStyle(style.color)
            .frame(width: size + 4, alignment: .center)
    }
}
