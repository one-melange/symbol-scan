import SwiftUI

/// How the picker resolved — drives what the controller does on close.
enum PickerAction {
    case inject      // insert the selected symbol into the source app
    case copy        // copy the selected symbol to the clipboard
    case dismiss     // close without selecting
    case chooseRepo  // open the directory picker to index a different repo
    case reindex     // rescan the active repo
}

struct SymbolPickerView: View {
    let trigger: EventTap.Trigger
    /// Called when the picker resolves (inject / copy / dismiss).
    let onResolve: (PickerAction) -> Void

    @StateObject private var vm: SymbolPickerViewModel
    @ObservedObject private var index: SymbolIndex

    private let rowHeight: CGFloat = 44

    init(viewModel: SymbolPickerViewModel,
         trigger: EventTap.Trigger,
         onResolve: @escaping (PickerAction) -> Void) {
        _vm = StateObject(wrappedValue: viewModel)
        _index = ObservedObject(wrappedValue: viewModel.index)
        self.trigger = trigger
        self.onResolve = onResolve
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.3)
            resultsList
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
            // Trigger badge
            Text(trigger.prefix.isEmpty ? "⌘⇧O" : trigger.prefix)
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

        // The borderless window must be key before it can hold first responder; defer a
        // tick so makeKeyAndOrderFront has run.
        DispatchQueue.main.async { [weak field] in
            field?.window?.makeFirstResponder(field)
        }
        return field
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

            // File path + line
            VStack(alignment: .trailing, spacing: 1) {
                Text(symbol.displayPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(":\(symbol.line)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
