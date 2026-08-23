import SwiftUI

/// The window's session tabs.
///
/// Drawn by the app rather than by AppKit — see `WindowModel` for why. Each tab is an independent
/// session: its own child process, approval broker, and agent tree.
struct SessionTabStrip: View {
    @Bindable var window: WindowModel

    private var model: AppModel { window.current }

    var body: some View {
        HStack(spacing: 0) {
            // The only toggle for either rail. It lives here because this row is always on screen,
            // so the same control that puts a rail away is the one that brings it back.
            IconButton(
                systemName: window.isSessionRailVisible ? "sidebar.leading" : "sidebar.left",
                help: window.isSessionRailVisible
                    ? "Hide the session rail (⌘⌥[)"
                    : "Show the session rail (⌘⌥[)",
                tint: window.isSessionRailVisible ? Theme.Colors.muted : Theme.Colors.subtle
            ) {
                window.toggleSessionRail()
            }
            .padding(.leading, Theme.Space.xs)
            .disabled(model.workspace == nil)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(window.tabs.enumerated()), id: \.element.id) { index, model in
                        SessionTab(
                            title: model.tabTitle,
                            state: model.sessionState,
                            isSelected: index == window.selection,
                            canClose: window.tabs.count > 1,
                            onSelect: { window.select(index) },
                            onClose: { window.close(index) })

                        if index < window.tabs.count - 1 {
                            Rectangle()
                                .fill(Theme.Colors.divider)
                                .frame(width: Theme.Layout.hairline, height: 18)
                        }
                    }
                }
            }

            IconButton(systemName: "plus", help: "New session in this project") {
                window.openBlankTab()
            }
            .padding(.horizontal, Theme.Space.xs)
            .disabled(model.workspace == nil)

            Spacer(minLength: Theme.Space.sm)

            versionBadge

            IconButton(
                systemName: window.isRunPanelVisible ? "sidebar.trailing" : "sidebar.right",
                help: window.isRunPanelVisible
                    ? "Hide the run panel (⌘⌥])"
                    : "Show the run panel (⌘⌥])",
                tint: window.isRunPanelVisible ? Theme.Colors.muted : Theme.Colors.subtle
            ) {
                window.toggleRunPanel()
            }
            .padding(.horizontal, Theme.Space.xs)
            .disabled(model.workspace == nil)
        }
        .frame(height: 34)
        .background(Theme.Colors.canvas)
    }

    /// The running version, on the same row as the tabs.
    ///
    /// It had a toolbar row of its own, which spent a whole band of the window on one short
    /// string. Clicking it checks for a newer release.
    private var versionBadge: some View {
        Button {
            model.updates.check()
        } label: {
            HStack(spacing: Theme.Space.xs) {
                if model.updates.isChecking {
                    Spinner(size: 9, color: Theme.Colors.subtle)
                } else if updateAvailable {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.accent)
                }
                Text("v\(model.appVersion)")
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(updateAvailable
                        ? Theme.Colors.accent
                        : Theme.Colors.subtle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(updateAvailable
            ? "A newer version is available"
            : "Machline \(model.appVersion) — click to check for updates")
    }

    private var updateAvailable: Bool {
        if case .available = model.updates.outcome { return true }
        return false
    }
}

struct SessionTab: View {
    let title: String
    let state: AppModel.SessionState
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            Text(title)
                .font(Theme.Typography.control)
                .foregroundStyle(isSelected ? Theme.Colors.textStrong : Theme.Colors.muted)
                .lineLimit(1)
                .truncationMode(.middle)

            // The close control appears on hover so a row of tabs is not a row of buttons.
            if canClose, isHovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Colors.subtle)
                }
                .buttonStyle(.plain)
                .help("Close this session")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 34)
        .frame(maxWidth: 240)
        .background(isSelected ? Theme.Colors.panel : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Theme.Colors.accent : .clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var tint: Color {
        switch state {
        case .running, .starting: return Theme.Colors.accent
        case .failed: return Theme.Colors.error
        case .exited(let status): return status == 0 ? Theme.Colors.subtle : Theme.Colors.error
        case .idle: return Theme.Colors.subtle
        }
    }
}

/// Paints the window's own background before SwiftUI draws, so a new window never flashes black.
struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.backgroundColor = NSColor(Theme.Colors.canvas)
        }
    }
}

/// The draggable divider between the timeline and the composer.
///
/// A one-pixel rule is too thin to grab, so the hit area is padded well beyond what is drawn and
/// the cursor changes on hover — otherwise the handle is invisible until found by accident.
struct ResizeHandle: View {
    /// Vertical drag since the last callback, in points. Positive is downward.
    let onDrag: (CGFloat) -> Void
    /// Called once when the drag finishes, for callers that persist the result.
    var onEnd: () -> Void = {}
    /// Double-click. The way back from a size that was dragged somewhere unusable.
    var onReset: () -> Void = {}

    @State private var isHovering = false
    @State private var isDragging = false
    /// A reference, not `@State`: this changes on every drag callback and rebuilding the handle
    /// for it is work done sixty times a second for nothing.
    @State private var drag = DragOrigin()

    final class DragOrigin {
        var lastTranslation: CGFloat = 0
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isHovering || isDragging ? Theme.Colors.accent : Theme.Colors.divider)
                .frame(height: Theme.Layout.hairline)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onReset)
        .onHover { hovering in
            isHovering = hovering
            // The cursor is the only affordance a one-pixel divider has.
            if hovering {
                NSCursor.resizeUpDown.push()
            } else if !isDragging {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        drag.lastTranslation = 0
                    }
                    // Deltas rather than absolute translation: the caller clamps, and feeding it
                    // an absolute value would fight that clamp on every frame.
                    onDrag(value.translation.height - drag.lastTranslation)
                    drag.lastTranslation = value.translation.height
                }
                .onEnded { _ in
                    isDragging = false
                    drag.lastTranslation = 0
                    onEnd()
                    if !isHovering { NSCursor.pop() }
                })
    }
}
