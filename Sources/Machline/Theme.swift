import SwiftUI

/// Gruvbox dark-hard visual tokens for the whole surface.
///
/// The palette is the upstream Gruvbox dark-hard set. Hierarchy is built from weight, family,
/// contrast, spacing, and one-pixel dividers rather than from extra hues, so adding a colour here
/// should be rare and deliberate.
enum Theme {

    // MARK: - Colour

    enum Colors {
        /// Window ground. Nothing else uses this.
        static let canvas = Color(hex: 0x1D2021)
        /// Rails and raised bands.
        static let panel = Color(hex: 0x282828)
        /// Cards, event surfaces, inputs.
        static let surface = Color(hex: 0x3C3836)
        static let hover = Color(hex: 0x504945)
        static let selection = Color(hex: 0x8EC07C, opacity: 0.20)
        static let border = Color(hex: 0x665C54)
        /// Dividers are quieter than borders; a full-strength rule reads as a box edge.
        static let divider = Color(hex: 0x3C3836)

        static let text = Color(hex: 0xD5C4A1)
        /// Prose that should out-weigh surrounding chrome.
        static let textStrong = Color(hex: 0xEBDBB2)
        static let muted = Color(hex: 0xA89984)
        static let subtle = Color(hex: 0x928374)

        static let accent = Color(hex: 0x8EC07C)
        static let accentHover = Color(hex: 0xB8BB26)
        static let accentActive = Color(hex: 0x689D6A)
        static let link = Color(hex: 0x83A598)
        static let code = Color(hex: 0xD79921)

        static let warning = Color(hex: 0xFABD2F)
        static let error = Color(hex: 0xFB4934)
        static let success = Color(hex: 0xB8BB26)
        static let info = Color(hex: 0x83A598)

        static let diffAdded = Color(hex: 0xB8BB26, opacity: 0.15)
        static let diffDeleted = Color(hex: 0xFB4934, opacity: 0.15)
        static let diffAddedText = Color(hex: 0xB8BB26)
        static let diffDeletedText = Color(hex: 0xFB4934)

        static let backdrop = Color(hex: 0x000000, opacity: 0.70)
    }

    // MARK: - Spacing

    /// Base unit is 4pt; every gap in the interface is one of these steps.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32

        /// Standard outer padding inside a rail.
        static let railPadding: CGFloat = 16
        /// Standard outer padding in the timeline, which reads at a longer measure.
        static let timelinePadding: CGFloat = 22
    }

    // MARK: - Layout

    /// Rails use fixed preferred widths with hard maximums. They must not scale with the window —
    /// extra width belongs to the timeline and to wide diffs.
    enum Layout {
        static let railWidth: CGFloat = 272
        static let railMinWidth: CGFloat = 248
        /// Wider than the reference design allows: session titles are whole sentences here.
        static let railMaxWidth: CGFloat = 420

        static let runPanelWidth: CGFloat = 440
        static let runPanelMinWidth: CGFloat = 288
        /// The run panel holds the Git workbench, so it earns real width on demand — a hunk view
        /// at 344pt wraps every line. The timeline keeps priority until the operator drags.
        static let runPanelMaxWidth: CGFloat = 1200

        /// Low enough that dragging a rail wide is not fought by the centre's own floor. Prose
        /// gets narrow here, but that is the operator's choice to make with the divider.
        static let centerMinWidth: CGFloat = 320

        /// The composer's default height. It is draggable from there — see `ResizeHandle`.
        static let composerHeight: CGFloat = 248
        /// Floor: the status strip and the control footer, plus one line of input.
        static let composerMinHeight: CGFloat = 128
        /// The composer never takes more than this share of the window; the timeline is the point.
        static let composerMaxFraction: CGFloat = 0.7
        static let composerStatusStrip: CGFloat = 40
        static let composerFooter: CGFloat = 64

        static let utilityRowHeight: CGFloat = 42
        static let iconButton: CGFloat = 28
        static let contextSummaryHeight: CGFloat = 80

        /// Embedded diffs are capped; Expand opens the complete file.
        static let embeddedDiffMaxHeight: CGFloat = 260
        static let toolOutputMaxHeight: CGFloat = 220

        static let windowMinWidth: CGFloat = 1180
        static let windowMinHeight: CGFloat = 760

        static let radius: CGFloat = 6
        static let hairline: CGFloat = 1
    }

    // MARK: - Typography

    /// Sans for interface and prose; monospace for code, commands, paths, and raw output.
    ///
    /// Every face cascades to Vazirmatn for Persian and Arabic — see `Fonts`. The cascade applies
    /// only to characters the primary face cannot draw, so Latin text is unaffected.
    enum Typography {
        /// 15/22 — user and assistant prose.
        static let prose = Fonts.ui(size: 15)
        static let proseLineSpacing: CGFloat = 7

        /// 14/20 medium — session titles, active agent role and activity.
        static let title = Fonts.ui(size: 14, weight: .medium)
        static let titleRegular = Fonts.ui(size: 14)

        /// 13/18 — navigation and controls.
        static let control = Fonts.ui(size: 13)
        static let controlMedium = Fonts.ui(size: 13, weight: .medium)

        /// 12/16 — metadata.
        static let meta = Fonts.ui(size: 12)

        /// 11/14 medium — uppercase section labels.
        static let sectionLabel = Fonts.ui(size: 11, weight: .medium)

        static let mono = Fonts.mono(size: 12.5)
        static let monoSmall = Fonts.mono(size: 11.5)
        static let monoMeta = Fonts.mono(size: 11)
        static let monoStrong = Fonts.mono(size: 12.5, weight: .medium)
    }
}

extension Color {
    /// `0xRRGGBB` with an optional separate alpha, so palette entries read as their hex source.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

// MARK: - Shared primitives

/// An uppercase section label. The quietest text in the interface, used to title a rail section.
struct SectionLabel: View {
    let text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(text.uppercased())
                .font(Theme.Typography.sectionLabel)
                .tracking(0.6)
                .foregroundStyle(Theme.Colors.subtle)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(Theme.Colors.subtle)
            }
        }
    }
}

/// A one-pixel rule. `Divider()` picks up the system separator colour, which is wrong here.
struct Hairline: View {
    var color: Color = Theme.Colors.divider

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: Theme.Layout.hairline)
            .frame(maxWidth: .infinity)
    }
}

/// A vertical one-pixel rule, for the gaps between rails.
struct VerticalHairline: View {
    var color: Color = Theme.Colors.divider

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: Theme.Layout.hairline)
            .frame(maxHeight: .infinity)
    }
}

/// A borderless square icon button sized to the control scale.
struct IconButton: View {
    let systemName: String
    var help: String = ""
    var tint: Color = Theme.Colors.muted
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: Theme.Layout.iconButton, height: Theme.Layout.iconButton)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Layout.radius)
                        .fill(isHovering ? Theme.Colors.hover : .clear))
                // A clear fill is not hit-tested, so without this the click target is the glyph's
                // own strokes and the rest of the square is dead. The rule holds anywhere a
                // button's visible box is larger than its label: give the box the hit shape.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// A small text button used in footers and section headers.
struct QuietButton: View {
    let title: String
    var role: Role = .normal
    var isEnabled: Bool = true
    let action: () -> Void

    enum Role { case normal, primary, danger }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.controlMedium)
                .foregroundStyle(foreground)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Layout.radius)
                        .fill(background))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Layout.radius)
                        .strokeBorder(Theme.Colors.border, lineWidth: role == .normal ? 1 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 && isEnabled }
    }

    private var foreground: Color {
        switch role {
        case .normal: return Theme.Colors.text
        case .primary: return Theme.Colors.canvas
        case .danger: return Theme.Colors.canvas
        }
    }

    private var background: Color {
        switch role {
        case .normal: return isHovering ? Theme.Colors.hover : Theme.Colors.surface
        case .primary: return isHovering ? Theme.Colors.accentHover : Theme.Colors.accent
        case .danger: return isHovering ? Theme.Colors.error.opacity(0.85) : Theme.Colors.error
        }
    }
}

/// A collapsible rail section. Used for everything demoted below the fold: completed agents, the
/// Git workbench, the MCP hub, diagnostics.
struct DisclosureSection<Content: View>: View {
    let title: String
    var count: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Text(title.uppercased())
                        .font(Theme.Typography.sectionLabel)
                        .tracking(0.6)
                        .foregroundStyle(Theme.Colors.subtle)
                    if let count {
                        Text(count)
                            .font(Theme.Typography.monoMeta)
                            .foregroundStyle(Theme.Colors.subtle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Colors.subtle)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, Theme.Space.railPadding)
                .padding(.vertical, Theme.Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.bottom, Theme.Space.md)
            }
        }
    }
}

/// A small spinning indicator for work in flight.
///
/// A static glyph on a button that is doing something reads as a stuck button. Driven by an
/// explicit `isActive` flag rather than by appearing and disappearing, so the animation restarts
/// cleanly each time rather than inheriting a half-finished rotation.
struct Spinner: View {
    var size: CGFloat = 10
    var color: Color = Theme.Colors.accent

    @State private var isSpinning = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(
                .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: isSpinning)
            .onAppear { isSpinning = true }
            .onDisappear { isSpinning = false }
    }
}
