import SwiftUI

/// The app's own controls.
///
/// AppKit's `Menu`, `Picker`, and `Toggle` bring their own materials, corner radii, focus rings,
/// and accent colour, none of which follow this theme — a row of them beside the flat Gruvbox
/// surfaces reads as a different application. These are drawn from the same tokens as everything
/// else, so a control looks like the interface it sits in.

/// A dropdown.
///
/// Presented in a popover rather than an `NSMenu`: a menu is drawn by AppKit and cannot be themed,
/// and the popover also gives room for a second line of detail per option, which several of these
/// selects need.
struct Select<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        var detail: String?
        var id: Value { value }

        init(_ value: Value, label: String, detail: String? = nil) {
            self.value = value
            self.label = label
            self.detail = detail
        }
    }

    @Binding var selection: Value
    let options: [Option]
    var placeholder = "—"
    var isEnabled = true
    /// Drawn in the theme's monospace, for values that are identifiers rather than prose.
    var isTechnical = true
    var tint: Color = Theme.Colors.text
    /// Forces the search field on for a list that is short today but long in general — the project
    /// list on a fresh machine, for instance.
    var showsSearch: Bool?
    var onSelect: ((Value) -> Void)?

    @State private var isOpen = false
    @State private var isHovering = false

    var body: some View {
        Button {
            guard isEnabled else { return }
            isOpen.toggle()
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(currentLabel)
                    .font(isTechnical ? Theme.Typography.monoStrong : Theme.Typography.control)
                    .foregroundStyle(isEnabled ? tint : Theme.Colors.subtle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.Colors.subtle)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering && isEnabled ? Theme.Colors.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SelectMenu(
                options: options,
                selection: selection,
                isTechnical: isTechnical,
                showsSearch: showsSearch
            ) { value in
                selection = value
                onSelect?(value)
                isOpen = false
            }
        }
    }

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? placeholder
    }
}

/// The popover body. Split out so the row highlighting and the filter own their own state.
private struct SelectMenu<Value: Hashable>: View {
    let options: [Select<Value>.Option]
    let selection: Value
    let isTechnical: Bool
    let showsSearch: Bool?
    let onChoose: (Value) -> Void

    @State private var search = ""
    @State private var highlighted = 0
    @FocusState private var isSearchFocused: Bool
    /// Focus for the list itself, so a select with no search field still takes the arrow keys.
    @FocusState private var isListFocused: Bool

    /// Below this many options the list is scannable at a glance and a search field is one more
    /// thing in the way.
    private static var searchThreshold: Int { 8 }

    private var hasSearch: Bool { showsSearch ?? (options.count >= Self.searchThreshold) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasSearch {
                searchField
                Hairline(color: Theme.Colors.border)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, option in
                            SelectRow(
                                label: option.label,
                                detail: option.detail,
                                isSelected: option.value == selection,
                                isHighlighted: index == highlighted,
                                isTechnical: isTechnical
                            ) {
                                onChoose(option.value)
                            }
                            .id(index)
                        }

                        if filtered.isEmpty {
                            Text("Nothing matches “\(search)”.")
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.subtle)
                                .padding(.horizontal, Theme.Space.md)
                                .padding(.vertical, Theme.Space.sm)
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
                .frame(maxHeight: 300)
                .onChange(of: highlighted) { _, index in
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .frame(minWidth: 240)
        .background(Theme.Colors.panel)
        // Focusable in its own right: a select with fewer options has no search field, so without
        // this nothing in the popover holds focus and the arrow keys reach no one.
        .focusable()
        .focused($isListFocused)
        .onAppear {
            // Open on whatever is currently chosen, so the first arrow press moves from there
            // rather than from the top of the list.
            highlighted = filtered.firstIndex { $0.value == selection } ?? 0
            if hasSearch { isSearchFocused = true } else { isListFocused = true }
        }
        // Typing narrows the list, so the highlight has to come back into range.
        .onChange(of: search) { _, _ in highlighted = 0 }
        .onKeyPress(phases: .down, action: handle)
    }

    /// Arrow keys move the highlight, Return and Tab commit it.
    ///
    /// Attached to both the list and the search field: a focused `TextField` consumes key presses
    /// before any ancestor sees them, so the same handler has to sit on it.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            move(by: -1)
            return .handled
        case .downArrow:
            move(by: 1)
            return .handled
        case .return, .tab:
            guard filtered.indices.contains(highlighted) else { return .ignored }
            onChoose(filtered[highlighted].value)
            return .handled
        default:
            return .ignored
        }
    }

    private func move(by offset: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        highlighted = ((highlighted + offset) % count + count) % count
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Colors.subtle)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.text)
                .focused($isSearchFocused)
                .onKeyPress(phases: .down, action: handle)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.subtle)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    /// Matches the label and the detail line, so a project can be found by its parent directory
    /// and a repository by its branch.
    private var filtered: [Select<Value>.Option] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return options }
        return options.filter {
            $0.label.lowercased().contains(query)
                || ($0.detail?.lowercased().contains(query) ?? false)
        }
    }
}

private struct SelectRow: View {
    let label: String
    let detail: String?
    let isSelected: Bool
    /// Where the keyboard is, which is not the same as what is chosen.
    let isHighlighted: Bool
    let isTechnical: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                // The tick keeps its column whether or not it is drawn, so labels stay aligned.
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.Colors.accent : .clear)
                    .frame(width: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(isTechnical ? Theme.Typography.monoMeta : Theme.Typography.control)
                        .foregroundStyle(isSelected ? Theme.Colors.textStrong : Theme.Colors.text)
                    if let detail {
                        Text(detail)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.subtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var background: some View {
        if isHighlighted {
            Theme.Colors.selection
        } else if isHovering {
            Theme.Colors.hover
        } else {
            Color.clear
        }
    }
}

/// A tick box.
struct CheckBox<Label: View>: View {
    @Binding var isOn: Bool
    var isEnabled = true
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    var body: some View {
        Button {
            guard isEnabled else { return }
            isOn.toggle()
        } label: {
            HStack(spacing: Theme.Space.sm) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isOn ? Theme.Colors.accent : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                isOn ? Theme.Colors.accent
                                    : (isHovering ? Theme.Colors.muted : Theme.Colors.border),
                                lineWidth: 1))
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.Colors.canvas)
                        }
                    }
                    .frame(width: 13, height: 13)

                label()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The system focus ring is a rounded rectangle around the whole label, which around a
        // 13pt box plus text reads as a stray highlight rather than as focus. The list itself
        // carries keyboard focus and drives the box with space, so the button never needs it.
        .focusable(false)
        .focusEffectDisabled()
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 && isEnabled }
    }
}

extension CheckBox where Label == EmptyView {
    init(isOn: Binding<Bool>, isEnabled: Bool = true) {
        self.init(isOn: isOn, isEnabled: isEnabled) { EmptyView() }
    }
}

/// A sliding switch, for settings that take effect immediately.
struct SwitchToggle<Label: View>: View {
    @Binding var isOn: Bool
    var isEnabled = true
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            guard isEnabled else { return }
            isOn.toggle()
        } label: {
            HStack(spacing: Theme.Space.sm) {
                label()
                Spacer(minLength: Theme.Space.sm)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Theme.Colors.accent.opacity(0.85) : Theme.Colors.surface)
                        .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
                    Circle()
                        .fill(isOn ? Theme.Colors.canvas : Theme.Colors.muted)
                        .padding(2)
                }
                .frame(width: 26, height: 15)
                .animation(.easeOut(duration: 0.12), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A segmented choice, for two or three mutually exclusive options shown at once.
struct SegmentedSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(option.value == selection
                            ? Theme.Colors.textStrong
                            : Theme.Colors.subtle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(option.value == selection ? Theme.Colors.hover : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.radius))
    }
}
