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
    case file       = "file"     // a repo file (any type) — T18
    case directory  = "dir"      // a repo directory — T18

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

enum Language: String, CaseIterable {
    case python     = "python"
    case typescript = "typescript"
    case rust       = "rust"
    case go         = "go"
    case swift      = "swift"

    static func detect(from url: URL) -> Language? {
        switch url.pathExtension.lowercased() {
        case "py":              return .python
        case "ts", "tsx":       return .typescript
        case "rs":              return .rust
        case "go":              return .go
        case "swift":           return .swift
        default:                return nil
        }
    }

    var extensions: [String] {
        switch self {
        case .python:       return ["py"]
        case .typescript:   return ["ts", "tsx"]
        case .rust:         return ["rs"]
        case .go:           return ["go"]
        case .swift:        return ["swift"]
        }
    }
}

// MARK: - File Entry

struct FileEntry {
    let path: String        // relative to repo root
    let language: Language
    var symbols: [Symbol]
    var indexedAt: Date
}
