import SwiftUI

struct SymbolPickerView: View {
    let index: SymbolIndex
    let trigger: EventTap.Trigger
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var results: [Symbol] = []
    @State private var selectedIndex: Int = 0
    @FocusState private var searchFocused: Bool

    private let rowHeight: CGFloat = 44

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
        .onAppear {
            results = index.search("")
            searchFocused = true

            // Pre-seed query from trigger prefix
            if trigger == .at { query = "" }
            if trigger == .hash { query = "" }
        }
        .onChange(of: query) { _, q in
            results = index.search(q)
            selectedIndex = 0
        }
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

            TextField("Search symbols…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular, design: .default))
                .focused($searchFocused)
                .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape, .tab]) { press in
                    switch press.key {
                    case .escape:            onDismiss(); return .handled
                    case .return:            confirmSelection(inject: true); return .handled
                    case .tab:               confirmSelection(inject: false); return .handled
                    case .upArrow:           moveSelection(-1); return .handled
                    case .downArrow:         moveSelection(+1); return .handled
                    default:                 return .ignored
                    }
                }

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
                    if results.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, sym in
                            SymbolRow(symbol: sym, isSelected: i == selectedIndex)
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedIndex = i; confirmSelection(inject: true) }
                                .onHover { if $0 { selectedIndex = i } }
                        }
                    }
                }
            }
            .frame(minHeight: rowHeight * 5, maxHeight: CGFloat(min(max(results.count, 5), 8)) * rowHeight + 8)
            .onChange(of: selectedIndex) { _, i in
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(index.symbolCount == 0 ? "No repo indexed" : "No results for \"\(query)\"")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if index.symbolCount == 0 {
                Text("Index a repo via the menu bar icon")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Actions

    private func confirmSelection(inject: Bool) {
        guard selectedIndex < results.count else { onDismiss(); return }
        let sym = results[selectedIndex]
        let text = sym.name

        onDismiss()

        if inject {
            onDismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                TextInjector.inject(text)
            }
        } else {
            TextInjector.copyToClipboard(text)
            onDismiss()
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
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
