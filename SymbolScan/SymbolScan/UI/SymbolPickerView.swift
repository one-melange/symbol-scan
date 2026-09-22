import SwiftUI
import AppKit
import Carbon

/// How the picker resolved — drives what the controller does on close.
enum PickerAction {
    case inject      // insert the selected symbol into the source app
    case copy        // copy the selected symbol to the clipboard
    case dismiss     // close without selecting
    case chooseRepo  // open the directory picker to index a different repo
    case reindex     // rescan the active repo
    case explain     // stream a local-LLM explanation of the selection (keeps the overlay open)
}

struct SymbolPickerView: View {
    /// Called when the picker resolves (inject / copy / dismiss).
    let onResolve: (PickerAction) -> Void

    @StateObject private var vm: SymbolPickerViewModel
    @ObservedObject private var index: SymbolIndex

    init(viewModel: SymbolPickerViewModel,
         onResolve: @escaping (PickerAction) -> Void) {
        _vm = StateObject(wrappedValue: viewModel)
        _index = ObservedObject(wrappedValue: viewModel.index)
        self.onResolve = onResolve
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.card) {
            searchBar
            Divider().opacity(Theme.Opacity.divider)
            resultsList
            if vm.explanation != .idle {
                explanationPane
            }
            statusBar
        }
        .background(Theme.Materials.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Colors.cardBorder, lineWidth: Theme.Stroke.cardBorder)
        )
        .shadow(color: Theme.Colors.cardShadow, radius: Theme.Shadow.radius, x: Theme.Shadow.x, y: Theme.Shadow.y)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: Theme.Spacing.searchBar) {
            // Trigger badge — the combo actually bound to the hotkey (reflects user config).
            Text(HotkeyPreference.load().displayString)
                .font(Theme.Fonts.triggerBadge)
                .foregroundStyle(.secondary)
                .padding(Theme.Padding.triggerBadge)
                .background(Theme.Materials.badgeFill)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge))

            // AppKit-backed field so navigation keys are intercepted at the field editor
            // level (see SearchFieldRepresentable) instead of via SwiftUI .onKeyPress,
            // which the field editor swallows once the field contains text.
            SearchFieldRepresentable(vm: vm, onResolve: onResolve)
                .frame(height: Theme.Metrics.searchFieldHeight)

            if index.isIndexing {
                ProgressView().scaleEffect(0.6)
            }
        }
        .padding(Theme.Padding.searchBar)
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: Theme.Spacing.list) {
                    if vm.results.isEmpty {
                        emptyState
                    } else {
                        // Identify rows by position so the list re-renders in place when
                        // results change. Keying by Symbol.id (UUID) here while each row
                        // also sets `.id(i)` gave SwiftUI two conflicting identities, so it
                        // retained stale rows (e.g. kept showing the empty-query results).
                        ForEach(Array(vm.results.enumerated()), id: \.offset) { i, sym in
                            SymbolRow(
                                symbol: sym,
                                isSelected: i == vm.selectedIndex,
                                showsDocumentationPopover: i == vm.selectedIndex
                                    && vm.isDocumentationPopoverPresented
                            )
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { vm.select(i); onResolve(.inject) }
                                .onHover { if $0 { vm.select(i) } }
                        }
                    }
                }
            }
            .frame(
                minHeight: Theme.Metrics.rowHeight * CGFloat(Theme.Metrics.visibleRowsMin),
                maxHeight: CGFloat(min(max(vm.results.count, Theme.Metrics.visibleRowsMin), Theme.Metrics.visibleRowsMax)) * Theme.Metrics.rowHeight + Theme.Metrics.listBottomPad
            )
            .onChange(of: vm.selectedIndex) { _, i in
                withAnimation(Theme.Motion.scroll) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    // MARK: - Explanation pane (⌘E)

    /// The local-LLM explanation, shown below the results while `explanation != .idle`. Streams text
    /// in as tokens arrive; caps its own height and scrolls so a long answer can't push the picker
    /// off-screen (the controller also grows the window when this appears).
    private var explanationPane: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.explanation) {
            Divider().opacity(Theme.Opacity.divider)
            HStack(spacing: Theme.Spacing.explanationHeader) {
                Image(systemName: "sparkles")
                    .font(Theme.Fonts.sparkles)
                    .foregroundStyle(.secondary)
                Text(vm.selectedSymbol()?.name ?? "Explanation")
                    .font(Theme.Fonts.explanationHeader)
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.explanation.isBusy {
                    ProgressView().scaleEffect(0.5)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(explanationBody)
                    .font(Theme.Fonts.explanationBody)
                    .foregroundStyle(explanationIsError ? Theme.Colors.error : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: Theme.Metrics.explanationMaxHeight)
        }
        .padding(Theme.Padding.explanation)
    }

    /// The text rendered in the pane for the current explanation state.
    private var explanationBody: String {
        switch vm.explanation {
        case .idle:             return ""
        case .preparing(let m): return m
        case .loading:          return "Thinking…"
        case .streaming(let s): return s
        case .done(let s):      return s
        case .failed(let m):    return m
        }
    }

    private var explanationIsError: Bool {
        if case .failed = vm.explanation { return true }
        return false
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: Theme.Spacing.statusBar) {
            if let root = index.indexedRepoRoot {
                Label(root.lastPathComponent, systemImage: "folder.fill")
                    .font(Theme.Fonts.statusLabel)
                    .foregroundStyle(Theme.Colors.statusStrong)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(index.symbolCount) symbols")
                .font(Theme.Fonts.statusCount)
                .foregroundStyle(Theme.Colors.statusStrong)
            Divider().frame(height: Theme.Metrics.statusDividerHeight)
            ForEach(["↵ inject", "⇥ copy", "⌘E explain", "esc dismiss", "⌘O repo", "⌘Q quit"], id: \.self) { hint in
                Text(hint)
                    .font(Theme.Fonts.statusHint)
                    .foregroundStyle(Theme.Colors.statusHint)
            }
        }
        .padding(Theme.Padding.statusBar)
        .background(Theme.Materials.statusBar)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        let copy = PickerEmptyState.copy(
            repoRoot: index.indexedRepoRoot,
            symbolCount: index.symbolCount,
            isIndexing: index.isIndexing,
            query: vm.query,
            error: index.lastIndexError
        )
        return VStack(spacing: Theme.Spacing.emptyState) {
            Text(copy.title)
                .font(Theme.Fonts.emptyTitle)
                .foregroundStyle(.secondary)
            if let hint = copy.hint {
                Text(hint)
                    .font(Theme.Fonts.emptyHint)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Padding.emptyState)
    }

}

// MARK: - Search Field (AppKit-backed)

/// An `NSTextField` wrapped for SwiftUI so we can intercept navigation/resolution keys
/// at the field-editor level. SwiftUI's `.onKeyPress` on a focused `TextField` is eaten
/// by the field editor (cursor movement) once the field has text — `doCommandBySelector`
/// runs *before* that, so arrows/return/tab/escape reach us reliably.
struct SearchFieldRepresentable: NSViewRepresentable {
    @ObservedObject var vm: SymbolPickerViewModel
    var onResolve: (PickerAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(vm: vm, onResolve: onResolve)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search symbols…"
        field.font = Theme.Fonts.searchField
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.stringValue = vm.query

        // The borderless window must be *key* before it can hold first responder. App activation
        // (in `OverlayWindowController.show`) is async, so the window isn't key on this runloop turn
        // — poll briefly until it is, then grab focus. Without this the field silently fails to
        // become first responder over apps that are slow to yield (notably terminals like iTerm),
        // leaving the search bar un-typeable until the user clicks it.
        Self.grabFocus(field, attempts: 25)
        return field
    }

    /// Make `field` first responder as soon as its window becomes key, retrying briefly. Each turn
    /// nudges the window toward key so activation that's still settling completes.
    private static func grabFocus(_ field: NSTextField?, attempts: Int) {
        guard let field else { return }
        guard let window = field.window else {
            // Not in the view hierarchy yet — try again shortly.
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { grabFocus(field, attempts: attempts - 1) }
            }
            return
        }
        if window.isKeyWindow {
            window.makeFirstResponder(field)
        } else if attempts > 0 {
            window.makeKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { grabFocus(field, attempts: attempts - 1) }
        }
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Keep the coordinator's closure fresh across re-renders.
        context.coordinator.onResolve = onResolve
        // Only write when different, so we don't reset the caret while the user types.
        if nsView.stringValue != vm.query {
            nsView.stringValue = vm.query
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let vm: SymbolPickerViewModel
        var onResolve: (PickerAction) -> Void

        init(vm: SymbolPickerViewModel, onResolve: @escaping (PickerAction) -> Void) {
            self.vm = vm
            self.onResolve = onResolve
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            vm.updateQuery(field.stringValue)
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                vm.moveSelection(-1);  return true
            case #selector(NSResponder.moveDown(_:)):
                vm.moveSelection(+1);  return true
            case #selector(NSResponder.insertNewline(_:)):
                onResolve(.inject);    return true
            case #selector(NSResponder.insertTab(_:)):
                onResolve(.copy);      return true
            case #selector(NSResponder.cancelOperation(_:)):
                onResolve(.dismiss);   return true
            default:
                return false
            }
        }
    }
}

// MARK: - Symbol Row

struct SymbolRow: View {
    let symbol: Symbol
    let isSelected: Bool
    let showsDocumentationPopover: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            // Kind badge
            Text(symbol.kind.icon)
                .font(Theme.Fonts.kindBadge)
                .foregroundStyle(Theme.Colors.badgeText)
                .frame(width: Theme.Metrics.badgeSize, height: Theme.Metrics.badgeSize)
                .background(Theme.Colors.kind(symbol.kind))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge))

            // Symbol name + signature
            VStack(alignment: .leading, spacing: Theme.Spacing.rowText) {
                Text(symbol.name)
                    .font(Theme.Fonts.rowName)
                    .foregroundStyle(.primary)

                if let sig = symbol.signature {
                    Text(sig)
                        .font(Theme.Fonts.rowDetail)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // File path + line (line is synthetic/0 for file & directory entries, so hide it there)
            VStack(alignment: .trailing, spacing: Theme.Spacing.rowText) {
                Text(symbol.displayPath)
                    .font(Theme.Fonts.rowDetail)
                    .foregroundStyle(.secondary)
                if symbol.kind != .file && symbol.kind != .directory {
                    Text(":\(symbol.line)")
                        .font(Theme.Fonts.rowDetail)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(Theme.Padding.row)
        .background(isSelected ? Theme.Colors.selection : .clear)
        .animation(Theme.Motion.selection, value: isSelected)
        // SwiftUI `.help` never presents from this floating, borderless accessory window on macOS
        // 26. Anchor an AppKit-owned popover to the selected row instead (T27).
        .background(DocumentationPopoverAnchor(
            text: symbol.documentationText,
            isPresented: showsDocumentationPopover
        ))
    }
}

// MARK: - Documentation popover

/// An invisible AppKit anchor spanning a symbol row. `NSPopover` presentation is managed outside
/// SwiftUI because `.help` resolves its text but does not create a visible tooltip window from the
/// picker's floating borderless `NSWindow` on macOS 26.
private struct DocumentationPopoverAnchor: NSViewRepresentable {
    let text: String
    let isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PopoverAnchorView {
        PopoverAnchorView()
    }

    func updateNSView(_ nsView: PopoverAnchorView, context: Context) {
        context.coordinator.update(text: text, isPresented: isPresented, anchor: nsView)
    }

    static func dismantleNSView(_ nsView: PopoverAnchorView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    final class Coordinator {
        private let contentController = DocumentationPopoverViewController()
        private let popover: NSPopover
        private var shouldPresent = false

        init() {
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.contentViewController = contentController
            self.popover = popover
        }

        func update(text: String, isPresented: Bool, anchor: NSView) {
            contentController.update(text: text)
            shouldPresent = isPresented

            guard isPresented else {
                popover.close()
                return
            }

            // A representable can update before AppKit has attached it to the hosting window. Defer
            // presentation one runloop turn and re-check state so a superseded row cannot flash.
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self, self.shouldPresent, let anchor, anchor.window != nil else { return }
                if !self.popover.isShown {
                    self.popover.show(
                        relativeTo: anchor.bounds,
                        of: anchor,
                        preferredEdge: .maxX
                    )
                }
            }
        }

        func dismiss() {
            shouldPresent = false
            popover.close()
        }
    }
}

/// A non-interactive anchoring view so the SwiftUI row keeps ownership of hover and click handling.
private final class PopoverAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Small native popover body with a fixed readable width and a bounded multiline label. Symbol docs
/// are capped at 1,000 characters during extraction; ten lines keeps the picker compact while still
/// surfacing substantially more context than the discarded one-line hover tooltip.
private final class DocumentationPopoverViewController: NSViewController {
    private let label = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.Fonts.popoverLabel
        label.textColor = .labelColor
        label.maximumNumberOfLines = 10
        label.lineBreakMode = .byWordWrapping

        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Theme.Metrics.popoverWidth),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Metrics.popoverInsetH),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Metrics.popoverInsetH),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Metrics.popoverInsetV),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Metrics.popoverInsetV),
        ])
        view = container
    }

    func update(text: String) {
        loadViewIfNeeded()
        guard label.stringValue != text else { return }
        label.stringValue = text
        label.invalidateIntrinsicContentSize()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Theme.Metrics.popoverWidth, height: max(view.fittingSize.height, Theme.Metrics.popoverMinHeight))
    }
}

// MARK: - Empty-state copy

/// Pure derivation of the picker's empty-state text from index state. Kept off the view (and off
/// `@MainActor`) so it can be unit-tested — including a regression guard that the "no repo" case
/// points at a real affordance (⌘O / the menu-bar icon), unlike the old hardcoded copy which
/// referenced a menu-bar icon that didn't exist.
enum PickerEmptyState {
    struct Copy: Equatable {
        let title: String
        let hint: String?
    }

    static func copy(repoRoot: URL?,
                     symbolCount: Int,
                     isIndexing: Bool,
                     query: String,
                     error: String?) -> Copy {
        if let error {
            let name = repoRoot?.lastPathComponent
            return Copy(title: name.map { "Couldn't index \($0)" } ?? "Couldn't index repo",
                        hint: error)
        }
        if isIndexing {
            let name = repoRoot?.lastPathComponent
            return Copy(title: name.map { "Indexing \($0)…" } ?? "Indexing…", hint: nil)
        }
        if repoRoot == nil {
            return Copy(title: "No repo selected",
                        hint: "Press ⌘O or use the menu-bar icon to choose a repo")
        }
        // A repo is active but the current query matches nothing (or it's genuinely empty).
        return Copy(title: "No results for \"\(query)\"", hint: nil)
    }
}

// MARK: - Hotkey settings (T6)

/// The trigger-rebinding pane, hosted by `PreferencesWindowController` (in AppDelegate.swift). Holds
/// the working `HotkeyBinding` in `@State`; `onChange` persists + live-reloads it, `onRecording`
/// suspends the global tap while a combo is being captured. There is a single configurable hotkey.
/// Lives here (with `KeyRecorderView`) rather than its own file so it builds without a project-file
/// edit.
struct HotkeySettingsView: View {
    @State private var binding: HotkeyBinding
    /// Shows a persistent "Saved" confirmation after a capture, so it's unambiguous the change stuck
    /// (recording alone only proves the combo was *read*). Cleared when a new recording starts.
    @State private var justSaved = false
    private let onChange: (HotkeyBinding) -> Void
    private let onRecording: (Bool) -> Void

    init(binding: HotkeyBinding = HotkeyPreference.load(),
         onChange: @escaping (HotkeyBinding) -> Void,
         onRecording: @escaping (Bool) -> Void) {
        _binding = State(initialValue: binding)
        self.onChange = onChange
        self.onRecording = onRecording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.settings) {
            Text("Trigger Hotkey").font(.headline)
            Text("Click the shortcut, then press a new key combination. A modifier is required; Esc cancels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Open the picker")
                    .font(Theme.Fonts.settingsRow)
                Spacer()
                KeyRecorderView(
                    binding: binding,
                    onCapture: { newBinding in
                        binding = newBinding
                        onChange(newBinding)
                        justSaved = true
                    },
                    onRecording: { recording in
                        if recording { justSaved = false }   // clear a stale confirmation mid-capture
                        onRecording(recording)
                    }
                )
                .frame(width: Theme.Metrics.recorderSize.width, height: Theme.Metrics.recorderSize.height)
            }

            // Saved confirmation. Reserve the row height either way so the layout doesn't jump.
            Group {
                if justSaved {
                    Label("Saved — \(binding.displayString) is now your hotkey", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.success)
                } else {
                    Text(" ").font(.caption)
                }
            }
            .frame(height: Theme.Metrics.savedRowHeight, alignment: .leading)

            Divider()
            Button("Restore Default") {
                binding = HotkeyPreference.defaultBinding
                onChange(binding)
                justSaved = true
            }
        }
        .padding(Theme.Padding.settings)
        .frame(width: Theme.Metrics.settingsPaneWidth)
    }
}

/// SwiftUI wrapper over `KeyRecorderNSView`. Modeled on `SearchFieldRepresentable` above — the
/// in-repo template for "SwiftUI needs responder-level key interception."
struct KeyRecorderView: NSViewRepresentable {
    let binding: HotkeyBinding
    let onCapture: (HotkeyBinding) -> Void
    let onRecording: (Bool) -> Void

    func makeNSView(context: Context) -> KeyRecorderNSView {
        KeyRecorderNSView(binding: binding, onCapture: onCapture, onRecording: onRecording)
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onRecording = onRecording
        nsView.setBindingIfIdle(binding)   // don't overwrite the label mid-capture
    }
}

/// A click-to-record shortcut field. Clicking makes it first responder and enters recording mode;
/// the next key combo (with at least one modifier) is captured, Esc cancels. Requires its window to
/// be key — the preferences window activates via `NSApp.activate`, same as the overlay.
final class KeyRecorderNSView: NSView {
    private(set) var binding: HotkeyBinding { didSet { needsDisplay = true } }
    var onCapture: (HotkeyBinding) -> Void
    var onRecording: (Bool) -> Void

    private var isRecording = false { didSet { needsDisplay = true } }
    private var hint: String?

    init(binding: HotkeyBinding,
         onCapture: @escaping (HotkeyBinding) -> Void,
         onRecording: @escaping (Bool) -> Void) {
        self.binding = binding
        self.onCapture = onCapture
        self.onRecording = onRecording
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Update the shown binding from SwiftUI, but not while the user is mid-capture (that would
    /// clobber the "Recording…" state).
    func setBindingIfIdle(_ newBinding: HotkeyBinding) {
        guard !isRecording else { return }
        if binding != newBinding { binding = newBinding }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { Theme.Metrics.recorderSize }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.Radius.recorder
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(Theme.Opacity.recorderRecordingFill) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? Theme.Stroke.recorderRecording : Theme.Stroke.recorderIdle
        path.stroke()

        let text = isRecording ? (hint ?? "Recording…") : binding.displayString
        let color: NSColor = (hint != nil) ? .systemRed : (isRecording ? .controlAccentColor : .labelColor)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.Fonts.recorder,
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    private func beginRecording() {
        guard !isRecording else { return }
        hint = nil
        isRecording = true
        onRecording(true)
    }

    private func endRecording() {
        guard isRecording else { return }
        hint = nil
        isRecording = false
        onRecording(false)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape {
            endRecording()   // cancel — keep the existing binding
            return
        }

        let modifiers = HotkeyModifiers(nsFlags: event.modifierFlags)
        guard !modifiers.isEmpty else {
            // A modifier-less key would fire on every keystroke — reject and keep recording.
            hint = "Needs a modifier"
            needsDisplay = true
            return
        }

        let captured = HotkeyBinding(keyCode: keyCode, modifiers: modifiers)
        binding = captured
        onCapture(captured)
        endRecording()
    }

    override func resignFirstResponder() -> Bool {
        endRecording()   // clicking away cancels an in-progress capture
        return super.resignFirstResponder()
    }
}
