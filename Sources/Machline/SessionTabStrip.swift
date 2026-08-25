import AppKit
import HarnessCore
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

            VersionBadge(model: model)

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
}

/// The running version, on the same row as the tabs. Clicking it checks for a newer release.
///
/// It had a toolbar row of its own, which spent a whole band of the window on one short string.
///
/// The answer comes back in a popover hung off the badge rather than in a banner across the top of
/// the window. As a row in the window's column, an answer nobody had asked to *see* — including
/// "you are up to date" — pushed the rails, the timeline and the composer down a band, and a
/// running download then re-laid the whole window out on every progress tick. A popover is drawn in
/// its own window, so the workspace underneath it does not move.
///
/// A view of its own for the same reason: the check and the transfer are the noisiest state in the
/// app, and reading them from the strip's body rebuilt every tab along with the badge.
struct VersionBadge: View {
    @Bindable var model: AppModel

    /// Whether the update card is open under the badge.
    @State private var isShowingUpdate = false

    var body: some View {
        Button {
            isShowingUpdate = true
            model.updates.check()
        } label: {
            HStack(spacing: Theme.Space.xs) {
                if model.updates.isChecking || isDownloading {
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
        .popover(isPresented: $isShowingUpdate, arrowEdge: .bottom) {
            UpdateCard(model: model) { isShowingUpdate = false }
        }
    }

    private var updateAvailable: Bool {
        if case .available = model.updates.outcome { return true }
        return false
    }

    /// A transfer started by a check the operator has since clicked away from still has to be
    /// visible somewhere, and the badge is the only thing left that is always on screen.
    private var isDownloading: Bool {
        if case .running = model.updates.download { return true }
        return false
    }
}

/// The result of an update check, and everything that follows from it.
///
/// Shown in a popover under the version badge — see `VersionBadge`. The check is
/// asked for, but everything after it is not: a new release downloads on its own and installs
/// itself, and this card is what makes that visible — and cancellable — while it happens. Nothing
/// is installed that has not matched the digest GitHub published.
struct UpdateCard: View {
    @Bindable var model: AppModel
    /// Closes the popover. Only the card knows when an action has finished what it was opened for.
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if model.updates.isChecking {
                row(icon: "arrow.triangle.2.circlepath", tint: Theme.Colors.subtle) {
                    Text("Checking for a newer release…")
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.Colors.muted)
                }
            } else if let outcome = model.updates.outcome {
                answer(outcome)
            } else {
                row(icon: "checkmark.circle", tint: Theme.Colors.subtle) {
                    Text("Machline \(model.appVersion).")
                        .font(Theme.Typography.control)
                        .foregroundStyle(Theme.Colors.muted)
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 340, alignment: .leading)
        .background(Theme.Colors.panel)
    }

    @ViewBuilder
    private func answer(_ outcome: UpdateCheck.Outcome) -> some View {
        switch outcome {
        case .available(let release):
            row(icon: "arrow.down.circle", tint: Theme.Colors.accent) {
                Text("Machline \(release.version) is available — you have \(model.appVersion).")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.text)
            }
            updateActions(for: release)
            // The offer is refusable, and refusing it has to mean something: it stops the transfer,
            // clears the answer, and takes the badge back out of its accented state.
            QuietButton(title: "Dismiss") {
                model.updates.dismissNotice()
                onClose()
            }

        case .upToDate:
            row(icon: "checkmark.circle", tint: Theme.Colors.success) {
                Text("Machline \(model.appVersion) is the latest release.")
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.muted)
            }

        case .unavailable(let reason):
            row(icon: "exclamationmark.circle", tint: Theme.Colors.subtle) {
                Text(reason)
                    .font(Theme.Typography.control)
                    .foregroundStyle(Theme.Colors.subtle)
            }
        }
    }

    /// An icon and its line of prose, on the card's one grid.
    private func row(
        icon: String, tint: Color, @ViewBuilder text: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            text()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The foot of the card: fetch the build, watch it arrive, open it.
    ///
    /// A release published without a build attached still gets the page, because then the page is
    /// genuinely the only thing there is.
    @ViewBuilder
    private func updateActions(for release: UpdateCheck.Release) -> some View {
        switch model.updates.download {
        case .running(let fraction):
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                        .monospacedDigit()
                }
                QuietButton(title: "Cancel") { model.updates.cancelDownload() }
            }

        case .finished(let file):
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if model.updates.canInstall {
                    // Only reached with a session mid-turn: the install is otherwise automatic.
                    Text("Downloaded — installing quits this session.")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.subtle)
                } else {
                    Text(file.lastPathComponent)
                        .font(Theme.Typography.monoMeta)
                        .foregroundStyle(Theme.Colors.subtle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: Theme.Space.sm) {
                    QuietButton(title: "Show in Finder") { model.updates.revealDownload() }
                    if model.updates.canInstall {
                        QuietButton(title: "Install and Relaunch", role: .primary) {
                            model.updates.install()
                        }
                    } else {
                        QuietButton(title: "Open", role: .primary) { model.updates.openDownload() }
                    }
                }
            }

        case .installing:
            Text("Installing \(release.version) — Machline will reopen.")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.subtle)

        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(message)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.sm) {
                    QuietButton(title: "Open release") { NSWorkspace.shared.open(release.url) }
                    QuietButton(title: "Retry", role: .primary) { model.updates.retryDownload() }
                }
            }

        case .idle:
            HStack(spacing: Theme.Space.sm) {
                QuietButton(title: "Release notes") { NSWorkspace.shared.open(release.url) }
                if let asset = release.asset {
                    QuietButton(title: downloadTitle(for: asset), role: .primary) {
                        model.updates.startDownload(release)
                    }
                }
            }
        }
    }

    /// The size is on the button because it is what decides whether now is a good moment.
    private func downloadTitle(for asset: UpdateCheck.Asset) -> String {
        guard asset.byteCount > 0 else { return "Download" }
        let megabytes = Double(asset.byteCount) / 1_000_000
        return String(format: "Download (%.1f MB)", megabytes)
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

// The window's own background is painted by `WindowChrome`, which also carries the frame and the
// close notification the restoration record needs.

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
