import Foundation
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterPython
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterJavaScript
import TreeSitterRust
import TreeSitterGo
import os

/// Tree-sitter–based symbol extractor — the only extractor now that the regex fallback has been
/// removed. Symbols come from a real parse tree, so method-vs-function is decided by node
/// ancestry rather than indentation heuristics, and declarations aren't missed/misread by
/// line-oriented regex.
///
/// `parse` returns an optional, but `nil` does **not** mean "this file failed": tree-sitter
/// error-recovers, so a syntactically broken file still yields `[]`. `nil` means the *grammar or
/// query for this language failed to build* — deterministic and cached-on-success, so it affects
/// every file of that language. `SymbolParser` turns that into a one-time warning. It never throws.
///
/// Per-language grammars + compiled queries are cached (query compilation is expensive). The
/// pure query text + kind-mapping logic is intentionally free of `@MainActor`/IO so it is
/// unit-testable in isolation, matching the `SymbolMatcher` separation.
enum TreeSitterParser {

    /// SwiftTreeSitter's `Language` collides with this module's `Language` enum; alias to keep
    /// the two unambiguous below.
    private typealias TSLanguage = SwiftTreeSitter.Language

    static func parse(source: String, language: Language, path: String) -> [Symbol]? {
        guard let grammar = grammar(for: language) else { return nil }

        let parser = Parser()
        do { try parser.setLanguage(grammar.tsLanguage) } catch { return nil }

        // `MutableTree.tree` is internal, so take a public `Tree` copy; `execute(node:in:)`
        // needs a `Tree`, and the tree must outlive the whole capture loop.
        guard let mutable = parser.parse(source),
              let tree = mutable.copy(),
              let root = tree.rootNode else { return nil }

        var symbols: [Symbol] = []
        let cursor = grammar.query.execute(node: root, in: tree)
        for match in cursor {
            for capture in match.captures {
                guard let tag = capture.name else { continue }
                let node = capture.node
                // `parse(_:)` encodes UTF-16, so `node.range` is a UTF-16 `NSRange` — slice the
                // String through it rather than any byte offset.
                guard let r = Range<String.Index>(node.range, in: source) else { continue }
                guard let kind = kind(forTag: tag, nameNode: node, language: language) else { continue }
                let name = String(source[r])
                symbols.append(Symbol(
                    name: name,
                    kind: kind,
                    filePath: path,
                    line: Int(node.pointRange.lowerBound.row) + 1,  // tree-sitter rows are 0-based
                    signature: signature(forTag: tag, nameNode: node, name: name,
                                         language: language, source: source),
                    doc: docComment(forTag: tag, nameNode: node, language: language, source: source)
                ))
            }
        }
        return symbols
    }

    // MARK: - Grammar cache

    private struct Grammar {
        let tsLanguage: TSLanguage
        let query: Query
    }

    private static let cacheLock = NSLock()
    private static var cache: [Language: Grammar] = [:]

    private static func grammar(for language: Language) -> Grammar? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[language] { return cached }
        guard let built = build(language) else { return nil }
        cache[language] = built
        return built
    }

    private static func build(_ language: Language) -> Grammar? {
        let tsLanguage: TSLanguage
        let queryText: String
        switch language {
        case .python:     tsLanguage = TSLanguage(language: tree_sitter_python());     queryText = pythonQuery
        case .typescript: tsLanguage = TSLanguage(language: tree_sitter_typescript()); queryText = typeScriptQuery
        // TSX shares TypeScript's node types for every pattern we match, so the query *text* is
        // reused — but a `Query` is bound to a `TSLanguage`, so it must be compiled and cached
        // separately.
        case .tsx:        tsLanguage = TSLanguage(language: tree_sitter_tsx());        queryText = typeScriptQuery
        case .javascript: tsLanguage = TSLanguage(language: tree_sitter_javascript()); queryText = javaScriptQuery
        case .rust:       tsLanguage = TSLanguage(language: tree_sitter_rust());       queryText = rustQuery
        case .go:         tsLanguage = TSLanguage(language: tree_sitter_go());         queryText = goQuery
        case .swift:      tsLanguage = TSLanguage(language: tree_sitter_swift());      queryText = swiftQuery
        }
        guard let data = queryText.data(using: .utf8),
              let query = try? Query(language: tsLanguage, data: data) else { return nil }
        return Grammar(tsLanguage: tsLanguage, query: query)
    }

    // MARK: - Kind resolution

    /// Map a capture tag (+ the captured name node, for context-dependent kinds) to a `SymbolKind`.
    /// Returns nil to drop the capture (e.g. Swift `extension` blocks, which aren't declarations).
    private static func kind(forTag tag: String, nameNode: Node, language: Language) -> SymbolKind? {
        switch tag {
        case "fn":        return isMethodContext(nameNode, language: language) ? .method : .function
        case "arrowfn":   return .function
        case "method":    return .method
        case "class":     return .class
        case "struct":    return .struct
        case "enum":      return .enum
        case "trait":     return .trait
        case "interface": return .interface
        case "type":      return .type
        case "protocol":  return .trait          // Swift protocols map to .trait, as in RegexParser
        case "typespec":  return goTypeKind(nameNode)
        case "classlike": return swiftClassKind(nameNode)
        default:          return nil
        }
    }

    /// True when a captured function/def is declared directly inside a type/impl body (→ method)
    /// rather than at file scope or nested in another function (→ function). Walks the ancestry of
    /// the declaration node, stopping at the first function boundary (nested func) or type
    /// container it meets.
    private static func isMethodContext(_ nameNode: Node, language: Language) -> Bool {
        let containers: Set<String>
        let functions: Set<String>
        switch language {
        case .python: containers = ["class_definition"];                     functions = ["function_definition"]
        case .rust:   containers = ["impl_item", "trait_item"];              functions = ["function_item"]
        case .swift:  containers = ["class_declaration", "protocol_declaration"]; functions = ["function_declaration"]
        // These capture methods via a dedicated pattern, so ancestry never decides the kind.
        case .go, .typescript, .tsx, .javascript: return false
        }
        // Skip the declaration node itself (nameNode.parent); walk its ancestors.
        var current = nameNode.parent?.parent
        while let node = current, let type = node.nodeType {
            if functions.contains(type) { return false }   // nested inside another function
            if containers.contains(type) { return true }
            current = node.parent
        }
        return false
    }

    /// Optional disambiguating text rendered under the name in the picker (`SymbolPickerView`).
    /// Only Go methods get one: `(*Server) Close` and `(Conn) Close` are otherwise indistinguishable
    /// in the results list apart from their line numbers. Everything else stays nil — the regex
    /// extractor's Python `def f(a, b)` isn't worth an extra node walk per definition, since name +
    /// `file:line` already identify it.
    private static func signature(forTag tag: String, nameNode: Node, name: String,
                                  language: Language, source: String) -> String? {
        guard language == .go, tag == "method",
              let decl = nameNode.parent, decl.nodeType == "method_declaration",
              let receiver = decl.child(byFieldName: "receiver"),   // parameter_list
              let param = receiver.namedChild(at: 0),               // parameter_declaration
              let type = param.child(byFieldName: "type"),          // type_identifier | pointer_type
              let r = Range<String.Index>(type.range, in: source) else { return nil }
        return "(\(source[r])) \(name)"
    }

    // MARK: - Doc-comment extraction

    /// Longest doc string we keep, to bound cache growth. Docs are collected but not yet surfaced,
    /// so a generous cap is fine — it only trims runaway file-header essays.
    private static let maxDocLength = 1_000

    /// Leading documentation for a captured symbol: a Python **body docstring**, or — for every
    /// other language — the *contiguous leading comment block* directly above the declaration (no
    /// blank-line gap). Cleaned (markers stripped, dedented, trimmed) and length-capped. `nil` when
    /// there is no adjacent doc. Pure and IO-free, like `signature`, so it's unit-testable.
    private static func docComment(forTag tag: String, nameNode: Node,
                                   language: Language, source: String) -> String? {
        if language == .python {
            return pythonDocstring(nameNode: nameNode, source: source)
        }
        return leadingCommentBlock(forTag: tag, nameNode: nameNode, language: language, source: source)
    }

    /// Python's docstring is not a comment but the first statement of the body when that statement
    /// is a bare string literal (`function_definition`/`class_definition` → `body` block → first
    /// named child).
    private static func pythonDocstring(nameNode: Node, source: String) -> String? {
        guard let body = nameNode.parent?.child(byFieldName: "body"),
              let first = body.namedChild(at: 0) else { return nil }
        let stringNode: Node
        if first.nodeType == "expression_statement", let s = first.namedChild(at: 0), s.nodeType == "string" {
            stringNode = s
        } else if first.nodeType == "string" {
            stringNode = first
        } else {
            return nil
        }
        guard let r = Range<String.Index>(stringNode.range, in: source) else { return nil }
        let cleaned = cleanPythonDocstring(String(source[r]))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Walk the preceding named siblings of the declaration's *anchor* node, collecting a contiguous
    /// run of comment nodes. A blank line (row gap > 1) or any non-comment, non-prelude sibling ends
    /// the block — the godoc adjacency rule, which keeps an unrelated file-header comment from being
    /// attached to the first declaration below it.
    private static func leadingCommentBlock(forTag tag: String, nameNode: Node,
                                            language: Language, source: String) -> String? {
        guard let anchor = docAnchor(forTag: tag, nameNode: nameNode, language: language) else { return nil }
        let comments = commentNodeTypes(language)
        let prelude = preludeNodeTypes(language)

        var collected: [Node] = []
        var nextStartRow = anchor.pointRange.lowerBound.row
        var sibling = anchor.previousNamedSibling
        while let node = sibling, let type = node.nodeType {
            let contiguous = Int(nextStartRow) - Int(node.pointRange.upperBound.row) <= 1
            if comments.contains(type) {
                if !contiguous { break }
                collected.append(node)
                nextStartRow = node.pointRange.lowerBound.row
            } else if prelude.contains(type) {
                // e.g. a Rust `#[attr]` between the doc comment and the item — part of the decl
                // prelude, so step over it (keeping the contiguity chain) rather than stopping.
                if !contiguous { break }
                nextStartRow = node.pointRange.lowerBound.row
            } else {
                break
            }
            sibling = node.previousNamedSibling
        }
        guard !collected.isEmpty else { return nil }

        // `collected` is bottom-up; restore source order, then strip markers line-by-line.
        var lines: [String] = []
        for node in collected.reversed() {
            guard let r = Range<String.Index>(node.range, in: source) else { continue }
            lines.append(contentsOf: stripCommentMarkers(String(source[r])))
        }
        let cleaned = normalizeDoc(lines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The node whose preceding siblings hold the doc comment. Usually the declaration itself
    /// (`nameNode.parent`), but a few captures are nested one level down, and TS/JS `export`-wrapped
    /// declarations put the comment above the `export_statement`.
    private static func docAnchor(forTag tag: String, nameNode: Node, language: Language) -> Node? {
        guard var anchor = nameNode.parent else { return nil }
        switch (language, tag) {
        case (.go, "typespec"): anchor = anchor.parent ?? anchor   // type_spec -> type_declaration
        case (_, "arrowfn"):    anchor = anchor.parent ?? anchor   // variable_declarator -> (lexical_)declaration
        default: break
        }
        if language == .typescript || language == .tsx || language == .javascript {
            while let p = anchor.parent, p.nodeType == "export_statement" { anchor = p }
        }
        return anchor
    }

    private static func commentNodeTypes(_ language: Language) -> Set<String> {
        switch language {
        case .swift: return ["comment", "multiline_comment"]
        case .rust:  return ["line_comment", "block_comment"]
        default:     return ["comment"]   // go, typescript, tsx, javascript
        }
    }

    /// Sibling node types that sit *between* a doc comment and its declaration and should be skipped
    /// without breaking the block. Only Rust outer attributes (`#[...]`) do this in practice.
    private static func preludeNodeTypes(_ language: Language) -> Set<String> {
        language == .rust ? ["attribute_item"] : []
    }

    /// Strip comment markers from one raw comment node's text, returning its cleaned line(s).
    /// Handles `///`/`//!`/`//` line comments and `/** */`/`/* */` block comments (dropping a
    /// leading `*` on interior block lines).
    private static func stripCommentMarkers(_ raw: String) -> [String] {
        // Trim newlines too: some grammars (e.g. tree-sitter-rust `line_comment`) include the
        // comment's trailing "\n" in the node range.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/*") {
            var body = trimmed
            body.removeFirst(2)                              // "/*"
            if body.hasPrefix("*") { body.removeFirst() }    // the extra "*" of a "/**" doc block
            if body.hasSuffix("*/") { body.removeLast(2) }
            return body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                var l = String(line).trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("*") {
                    l.removeFirst()
                    if l.hasPrefix(" ") { l.removeFirst() }
                }
                return l
            }
        }
        var l = trimmed
        for marker in ["///", "//!", "//"] where l.hasPrefix(marker) {   // longest first
            l.removeFirst(marker.count)
            break
        }
        if l.hasPrefix(" ") { l.removeFirst() }
        return [l]
    }

    /// Strip a Python string literal down to its content: drop an optional `r`/`b`/`u`/`f` prefix
    /// and the surrounding `"""`/`'''`/`"`/`'` delimiters, then normalize.
    private static func cleanPythonDocstring(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = s.first, "rbufRBUF".contains(f) { s.removeFirst() }
        for quote in ["\"\"\"", "'''", "\"", "'"] where s.hasPrefix(quote) && s.hasSuffix(quote) && s.count >= 2 * quote.count {
            s = String(s.dropFirst(quote.count).dropLast(quote.count))
            break
        }
        return normalizeDoc(s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    /// Shared cleanup for a doc's lines: strip trailing whitespace, drop leading/trailing blank
    /// lines, dedent by the common leading indent (matters for Python docstrings), join, and cap.
    private static func normalizeDoc(_ input: [String]) -> String {
        var lines = input.map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
        while let f = lines.first, f.isEmpty { lines.removeFirst() }
        while let l = lines.last, l.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return "" }

        // Dedent by the common indent of the lines *after* the first — PEP 257's rule, since a
        // docstring's opening line sits right after `"""` with no indent while its body is indented.
        // Comment blocks (all lines already at indent 0) are unaffected.
        let bodyIndents = lines.enumerated()
            .filter { $0.offset > 0 && !$0.element.isEmpty }
            .map { $0.element.prefix { $0 == " " || $0 == "\t" }.count }
        let minIndent = bodyIndents.min() ?? 0
        if minIndent > 0 {
            lines = lines.enumerated().map { i, l in
                i == 0 || l.isEmpty ? l : String(l.dropFirst(min(minIndent, l.count)))
            }
        }

        var result = lines.joined(separator: "\n")
        if result.count > maxDocLength {
            result = String(result.prefix(maxDocLength)) + "…"
        }
        return result
    }

    /// Go `type Foo <...>`: distinguish struct / interface / plain alias by the `type_spec`'s
    /// `type` child.
    private static func goTypeKind(_ nameNode: Node) -> SymbolKind {
        switch nameNode.parent?.child(byFieldName: "type")?.nodeType {
        case "struct_type":    return .struct
        case "interface_type": return .interface
        default:               return .type
        }
    }

    /// Swift `class_declaration` is reused for class/struct/enum/actor/extension — split on its
    /// `declaration_kind` keyword. `extension` isn't a declaration we index, so return nil.
    private static func swiftClassKind(_ nameNode: Node) -> SymbolKind? {
        switch nameNode.parent?.child(byFieldName: "declaration_kind")?.nodeType {
        case "struct":    return .struct
        case "enum":      return .enum
        case "class":     return .class
        case "actor":     return .class
        case "extension": return nil
        default:          return .class
        }
    }

    // MARK: - Per-language queries
    //
    // Capture tags encode the SymbolKind (resolved in `kind(forTag:...)`). Node/field names are
    // taken from each grammar's node-types.json.

    private static let pythonQuery = """
    (function_definition name: (identifier) @fn)
    (class_definition name: (identifier) @class)
    """

    private static let goQuery = """
    (function_declaration name: (identifier) @fn)
    (method_declaration name: (field_identifier) @method)
    (type_spec name: (type_identifier) @typespec)
    """

    private static let rustQuery = """
    (function_item name: (identifier) @fn)
    (struct_item name: (type_identifier) @struct)
    (enum_item name: (type_identifier) @enum)
    (trait_item name: (type_identifier) @trait)
    (type_item name: (type_identifier) @type)
    """

    /// Shared by `.typescript` and `.tsx` — the TSX grammar names these nodes and fields
    /// identically, it just also understands JSX.
    private static let typeScriptQuery = """
    (function_declaration name: (identifier) @fn)
    (generator_function_declaration name: (identifier) @fn)
    (class_declaration name: (type_identifier) @class)
    (abstract_class_declaration name: (type_identifier) @class)
    (interface_declaration name: (type_identifier) @interface)
    (type_alias_declaration name: (type_identifier) @type)
    (method_definition name: [(property_identifier) (private_property_identifier)] @method)
    (variable_declarator name: (identifier) @arrowfn value: [(arrow_function) (function_expression)])
    """

    /// JavaScript (`.js`/`.jsx`). Deliberately **not** a copy of `typeScriptQuery`: JS names classes
    /// with `(identifier)` where TS uses `(type_identifier)`, and has no `interface_declaration`,
    /// `type_alias_declaration` or `abstract_class_declaration` at all. Referencing any of those
    /// makes `Query(language:data:)` throw, which with no regex fallback would silently zero out
    /// every `.js` file — `everyDialectBuildsAGrammarAndQuery` guards exactly that.
    ///
    /// Known gap (shared with TypeScript): class-field arrow functions (`handleClick = () => {}`)
    /// are `field_definition`/`property` in JS but `public_field_definition`/`name` in TS, and
    /// neither dialect captures them today.
    private static let javaScriptQuery = """
    (function_declaration name: (identifier) @fn)
    (generator_function_declaration name: (identifier) @fn)
    (class_declaration name: (identifier) @class)
    (method_definition name: [(property_identifier) (private_property_identifier)] @method)
    (variable_declarator name: (identifier) @arrowfn value: [(arrow_function) (function_expression)])
    """

    private static let swiftQuery = """
    (function_declaration name: (simple_identifier) @fn)
    (class_declaration name: (type_identifier) @classlike)
    (protocol_declaration name: (type_identifier) @protocol)
    (typealias_declaration name: (type_identifier) @type)
    """
}

// MARK: - Parser facade

/// Single entry point the index uses. Tree-sitter is the only extractor: the regex fallback was
/// removed because it was unreachable — `TreeSitterParser.parse` returns nil only when a grammar
/// or query fails to *build*, which is deterministic and cached-on-success, and a merely broken
/// source file still parses to `[]` via error recovery.
enum SymbolParser {
    /// Files larger than this are skipped before we even read them. Catches large generated/data
    /// files (the `isMinified` line-length check only fires *after* the whole file is read into a
    /// `String`, which is itself wasteful for a multi-megabyte blob). Well above any hand-written
    /// source file; the caller still records an oversized file as a searchable `.file` entry.
    static let maxParseFileSizeBytes = 2 * 1024 * 1024

    static func parse(url: URL, language: Language, relativePath: String) throws -> [Symbol] {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxParseFileSizeBytes {
            return []
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        return parse(source: source, language: language, path: relativePath)
    }

    /// Non-optional: a nil from `TreeSitterParser` is a build failure for `language` as a whole,
    /// not for this file, so there's nothing to fall back to. Report it once per language rather
    /// than silently returning `[]` — silence is exactly how the `.tsx` routing bug went unnoticed.
    static func parse(source: String, language: Language, path: String) -> [Symbol] {
        guard !isMinified(source) else { return [] }
        guard let symbols = TreeSitterParser.parse(source: source, language: language, path: path) else {
            reportGrammarFailure(language)
            return []
        }
        return symbols
    }

    /// Longest line a hand-written source file is assumed to stay under. Measured across 174 real
    /// `.js`/`.ts`/`.tsx` files: hand-written topped out at 1,289 characters, while minified
    /// bundles hit 628,095 — a ~500× gap, so the exact threshold isn't delicate.
    static let minifiedLineThreshold = 5_000

    /// Minified/generated output is a single enormous line of mangled identifiers: two committed
    /// Vite bundles alone yielded 16,901 junk symbols (`ur`, `Rr`, `Sm`, …) that would swamp the
    /// picker. Name patterns don't catch it — Vite emits `index-DJ7HgGZS.js`, not `*.min.js` — so
    /// screen on the shape of the content instead. Checked here rather than in `Language.detect`
    /// because the source is already in hand, keeping detection pure and IO-free. Complements the
    /// `maxParseFileSizeBytes` pre-read byte cap above (which catches large files by size before
    /// they're read at all); this catches sub-cap files that are minified onto one long line.
    static func isMinified(_ source: String) -> Bool {
        var lineLength = 0
        for char in source.unicodeScalars {
            if char == "\n" {
                lineLength = 0
            } else {
                lineLength += 1
                if lineLength > minifiedLineThreshold { return true }
            }
        }
        return false
    }

    // Indexing runs on a detached task, so the once-per-language guard needs a lock — same pattern
    // as `TreeSitterParser.cacheLock`.
    private static let reportLock = NSLock()
    private static var reportedFailures: Set<Language> = []

    private static func reportGrammarFailure(_ language: Language) {
        reportLock.lock()
        defer { reportLock.unlock() }
        guard reportedFailures.insert(language).inserted else { return }
        Log.parser.error("Tree-sitter grammar/query failed to build for \(language.rawValue, privacy: .public) — no symbols will be indexed for those files")
    }
}
