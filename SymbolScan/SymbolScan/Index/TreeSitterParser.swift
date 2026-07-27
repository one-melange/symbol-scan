import Foundation
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterPython
import TreeSitterTypeScript
import TreeSitterRust
import TreeSitterGo

/// Tree-sitter–based symbol extractor (T16) — the only extractor since T21 removed the regex
/// fallback. Symbols come from a real parse tree, so method-vs-function is decided by node
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
                                         language: language, source: source)
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
        case .go, .typescript: return false     // these capture methods via a dedicated pattern
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

    private static let typeScriptQuery = """
    (function_declaration name: (identifier) @fn)
    (class_declaration name: (type_identifier) @class)
    (abstract_class_declaration name: (type_identifier) @class)
    (interface_declaration name: (type_identifier) @interface)
    (type_alias_declaration name: (type_identifier) @type)
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

/// Single entry point the index uses. Tree-sitter is the only extractor: T21 removed the regex
/// fallback because it was unreachable — `TreeSitterParser.parse` returns nil only when a grammar
/// or query fails to *build*, which is deterministic and cached-on-success, and a merely broken
/// source file still parses to `[]` via error recovery.
enum SymbolParser {
    static func parse(url: URL, language: Language, relativePath: String) throws -> [Symbol] {
        let source = try String(contentsOf: url, encoding: .utf8)
        return parse(source: source, language: language, path: relativePath)
    }

    /// Non-optional: a nil from `TreeSitterParser` is a build failure for `language` as a whole,
    /// not for this file, so there's nothing to fall back to. Report it once per language rather
    /// than silently returning `[]` — silence is exactly how the `.tsx` bug (T20) went unnoticed.
    static func parse(source: String, language: Language, path: String) -> [Symbol] {
        guard let symbols = TreeSitterParser.parse(source: source, language: language, path: path) else {
            reportGrammarFailure(language)
            return []
        }
        return symbols
    }

    // Indexing runs on a detached task, so the once-per-language guard needs a lock — same pattern
    // as `TreeSitterParser.cacheLock`.
    private static let reportLock = NSLock()
    private static var reportedFailures: Set<Language> = []

    private static func reportGrammarFailure(_ language: Language) {
        reportLock.lock()
        defer { reportLock.unlock() }
        guard reportedFailures.insert(language).inserted else { return }
        print("⚠️ Tree-sitter grammar/query failed to build for \(language.rawValue) — "
              + "no symbols will be indexed for those files")
    }
}
