import Foundation

// MARK: - Symbol

struct Symbol: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let kind: SymbolKind
    let filePath: String       // relative to repo root
    let line: Int
    let signature: String?     // full function signature if available

    init(name: String, kind: SymbolKind, filePath: String, line: Int, signature: String? = nil) {
        self.id = UUID()
        self.name = name
        self.kind = kind
        self.filePath = filePath
        self.line = line
        self.signature = signature
    }

    var displayPath: String {
        // Truncate long paths: show last 2 components
        let parts = filePath.split(separator: "/").map(String.init)
        return parts.suffix(2).joined(separator: "/")
    }

    /// The reference **body** injected (or copied) when this entry is picked — the leading
    /// prefix marker (`@` / `#`) is NOT included here: for the `@`/`#` triggers the user has
    /// already typed it into the target app (see `EventTap`, which passes those keys through),
    /// and the overlay supplies one for the `⌘⇧O` trigger. Prepending it here would double it
    /// (`@@…`). Kept pure so it's unit-testable. Two shapes by kind:
    /// - code symbols → `<relativePath>:<line> <name>` (the `file:line` editor convention,
    ///   followed by the symbol name), e.g. `Index/SymbolIndex.swift:105 search`.
    /// - file / directory entries → `<name> <relative-parent-dir>`, e.g.
    ///   `SymbolIndex.swift Index` or `Index src`. An entry at the repo root has no parent, so
    ///   just `<name>` (no trailing space).
    var injectionText: String {
        switch kind {
        case .file, .directory:
            let parent = (filePath as NSString).deletingLastPathComponent
            return parent.isEmpty ? name : "\(name) \(parent)"
        default:
            return "\(filePath):\(line) \(name)"
        }
    }
}

// MARK: - Symbol Kind

enum SymbolKind: String, CaseIterable, Codable {
    case function   = "func"
    case method     = "method"
    case `class`    = "class"
    case `struct`   = "struct"
    case `enum`     = "enum"
    case trait      = "trait"    // Rust
    case interface  = "interface"
    case constant   = "const"
    case variable   = "var"
    case type       = "type"     // Go type aliases, Rust type aliases
    case file       = "file"     // a repo file (any type)
    case directory  = "dir"      // a repo directory

    var icon: String {
        switch self {
        case .function:  return "ƒ"
        case .method:    return "m"
        case .class:     return "C"
        case .struct:    return "S"
        case .enum:      return "E"
        case .trait:     return "T"
        case .interface: return "I"
        case .constant:  return "K"
        case .variable:  return "V"
        case .type:      return "τ"
        case .file:      return "F"
        case .directory: return "D"
        }
    }

    var color: String {
        // Used in SwiftUI as named colors — define these in Assets.xcassets
        switch self {
        case .function, .method:           return "symbolFunc"
        case .class, .struct:              return "symbolType"
        case .enum, .trait, .interface:    return "symbolEnum"
        case .constant, .variable, .type:  return "symbolVar"
        case .file, .directory:            return "symbolPath"
        }
    }
}

// MARK: - Language

/// The **parse dialect** of a source file — i.e. which Tree-sitter grammar to use. Deliberately
/// not "programming language": `.typescript` and `.tsx` are the same language but *different*
/// grammars (the TS grammar can't parse JSX — it error-recovers past it, so symbols silently
/// vanish rather than failing loudly; that was the .tsx-vs-JSX routing bug).
///
/// Nothing renders this value and nothing persists it (`Symbol`, the only `Codable` type here, has
/// no language field), so the raw values are free to change. Its only two jobs are the extension
/// filter below and grammar selection in `TreeSitterParser.build`.
enum Language: String, CaseIterable {
    case python     = "python"
    case typescript = "typescript"
    case tsx        = "tsx"          // TypeScript + JSX — a separate grammar
    case javascript = "javascript"   // .js / .jsx — tree-sitter-javascript parses JSX natively,
                                     // so unlike TS/TSX there's no separate JSX dialect
    case rust       = "rust"
    case go         = "go"
    case swift      = "swift"

    static func detect(from url: URL) -> Language? {
        // Minified and bundled JS is routinely committed, and one such file yields thousands of
        // junk one-character symbols from a single line. `git ls-files` is the primary enumeration
        // path and doesn't honour `RepoScanner.excludedDirs`, so screen them by name here; a
        // general file-size cap is still TODO.
        let fileName = url.lastPathComponent.lowercased()
        guard !fileName.hasSuffix(".min.js"), !fileName.hasSuffix(".bundle.js") else { return nil }

        switch url.pathExtension.lowercased() {
        case "py":                      return .python
        case "ts", "mts", "cts":        return .typescript
        case "tsx":                     return .tsx
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "rs":                      return .rust
        case "go":                      return .go
        case "swift":                   return .swift
        default:                        return nil
        }
    }
}
