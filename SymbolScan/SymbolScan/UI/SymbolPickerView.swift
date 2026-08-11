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

    private let rowHeight: CGFloat = 44

    init(viewModel: SymbolPickerViewModel,
         onResolve: @escaping (PickerAction) -> Void) {
        _vm = StateObject(wrappedValue: viewModel)
        _index = ObservedObject(wrappedValue: viewModel.index)
        self.onResolve = onResolve
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.3)
            resultsList
            if vm.explanation != .idle {
                explanationPane
            }
            statusBar
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 8)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            // Trigger badge — the combo actually bound to the hotkey (reflects user config).
            Text(HotkeyPreference.load().displayString)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // AppKit-backed field so navigation keys are intercepted at the field editor
            // level (see SearchFieldRepresentable) instead of via SwiftUI .onKeyPress,
            // which the field editor swallows once the field contains text.
            SearchFieldRepresentable(vm: vm, onResolve: onResolve)
                .frame(height: 20)

            if index.isIndexing {
                ProgressView().scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if vm.results.isEmpty {
                        emptyState
                    } else {
                        // Identify rows by position so the list re-renders in place when
                        // results change. Keying by Symbol.id (UUID) here while each row
                        // also sets `.id(i)` gave SwiftUI two conflicting identities, so it
                        // retained stale rows (e.g. kept showing the empty-query results).
                        ForEach(Array(vm.results.enumerated()), id: \.offset) { i, sym in
                            SymbolRow(symbol: sym, isSelected: i == vm.selectedIndex)
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { vm.selectedIndex = i; onResolve(.inject) }
                                .onHover { if $0 { vm.selectedIndex = i } }
                        }
                    }
                }
            }
            .frame(minHeight: rowHeight * 5, maxHeight: CGFloat(min(max(vm.results.count, 5), 8)) * rowHeight + 8)
            .onChange(of: vm.selectedIndex) { _, i in
                withAnimation(.easeInOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    // MARK: - Explanation pane (⌘E)

    /// The local-LLM explanation, shown below the results while `explanation != .idle`. Streams text
    /// in as tokens arrive; caps its own height and scrolls so a long answer can't push the picker
    /// off-screen (the controller also grows the window when this appears).
    private var explanationPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.3)
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(vm.selectedSymbol()?.name ?? "Explanation")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.explanation.isBusy {
                    ProgressView().scaleEffect(0.5)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(explanationBody)
                    .font(.system(size: 12))
                    .foregroundStyle(explanationIsError ? Color.red : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The text rendered in the pane for the current explanation state.
    private var explanationBody: String {
        switch vm.explanation {
        case .idle:            return ""
        case .loading:         return "Thinking…"
        case .streaming(let s): return s
        case .done(let s):     return s
        case .failed(let m):   return m
        }
    }

    private var explanationIsError: Bool {
        if case .failed = vm.explanation { return true }
        return false
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            if let root = index.indexedRepoRoot {
                Label(root.lastPathComponent, systemImage: "folder.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(index.symbolCount) symbols")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Divider().frame(height: 10)
            Text("↵ inject")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            Text("⇥ copy")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            Text("⌘E explain")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            Text("esc dismiss")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            Text("⌘O repo")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            Text("⌘Q quit")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
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
        return VStack(spacing: 6) {
            Text(copy.title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if let hint = copy.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
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
        field.font = .systemFont(ofSize: 15, weight: .regular)
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

    var body: some View {
        HStack(spacing: 10) {
            // Kind badge
            Text(symbol.kind.icon)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(kindColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Symbol name + signature
            VStack(alignment: .leading, spacing: 1) {
                Text(symbol.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)

                if let sig = symbol.signature {
                    Text(sig)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // File path + line (line is synthetic/0 for file & directory entries, so hide it there)
            VStack(alignment: .trailing, spacing: 1) {
                Text(symbol.displayPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if symbol.kind != .file && symbol.kind != .directory {
                    Text(":\(symbol.line)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .animation(.easeInOut(duration: 0.08), value: isSelected)
    }

    private var kindColor: Color {
        switch symbol.kind {
        case .function, .method:          return .blue
        case .class, .struct:             return .purple
        case .enum, .trait, .interface:   return .orange
        case .constant, .variable, .type: return .green
        case .file, .directory:           return .gray
        }
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Trigger Hotkey").font(.headline)
            Text("Click the shortcut, then press a new key combination. A modifier is required; Esc cancels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Open the picker")
                    .font(.system(size: 13))
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
                .frame(width: 130, height: 26)
            }

            // Saved confirmation. Reserve the row height either way so the layout doesn't jump.
            Group {
                if justSaved {
                    Label("Saved — \(binding.displayString) is now your hotkey", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(" ").font(.caption)
                }
            }
            .frame(height: 16, alignment: .leading)

            Divider()
            Button("Restore Default") {
                binding = HotkeyPreference.defaultBinding
                onChange(binding)
                justSaved = true
            }
        }
        .padding(20)
        .frame(width: 380)
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
    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text = isRecording ? (hint ?? "Recording…") : binding.displayString
        let color: NSColor = (hint != nil) ? .systemRed : (isRecording ? .controlAccentColor : .labelColor)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
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
