import Foundation

/// Regex-based symbol extractor.
/// Tree-sitter would be more accurate but requires native dylibs per grammar.
/// This gets you to 90%+ coverage for the four target languages with zero dependencies.
/// Swap in Tree-sitter later per file if you want higher fidelity.
struct RegexParser {

    static func parse(url: URL, language: Language) throws -> [Symbol] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let relativePath = url.lastPathComponent // caller should pass full relative path

        switch language {
        case .python:     return parsePython(content, path: relativePath)
        case .typescript: return parseTypeScript(content, path: relativePath)
        case .rust:       return parseRust(content, path: relativePath)
        case .go:         return parseGo(content, path: relativePath)
        case .swift:      return parseSwift(content, path: relativePath)
        }
    }

    // MARK: - Python

    private static func parsePython(_ src: String, path: String) -> [Symbol] {
        var symbols: [Symbol] = []
        let lines = src.components(separatedBy: "\n")

        let funcPattern  = /^(?:async\s+)?def\s+(\w+)\s*\(([^)]*)\)/
        let classPattern = /^class\s+(\w+)[\s:(]/

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let match = trimmed.firstMatch(of: funcPattern) {
                let isMethod = line.first == " " || line.first == "\t"
                symbols.append(Symbol(
                    name: String(match.1),
                    kind: isMethod ? .method : .function,
                    filePath: path,
                    line: i + 1,
                    signature: "def \(match.1)(\(match.2))"
                ))
            } else if let match = trimmed.firstMatch(of: classPattern) {
                symbols.append(Symbol(
                    name: String(match.1),
                    kind: .class,
                    filePath: path,
                    line: i + 1
                ))
            }
        }
        return symbols
    }

    // MARK: - TypeScript

    private static func parseTypeScript(_ src: String, path: String) -> [Symbol] {
        var symbols: [Symbol] = []
        let lines = src.components(separatedBy: "\n")

        // function foo( / async function foo(
        let funcPattern    = /(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*[<(]/
        // const foo = ( / const foo = async (
        let arrowPattern   = /(?:export\s+)?(?:const|let)\s+(\w+)\s*=\s*(?:async\s*)?\(/
        // class Foo
        let classPattern   = /(?:export\s+)?(?:abstract\s+)?class\s+(\w+)/
        // interface Foo
        let ifacePattern   = /(?:export\s+)?interface\s+(\w+)/
        // type Foo =
        let typePattern    = /(?:export\s+)?type\s+(\w+)\s*=/
        // foo( method inside class — indented, no function keyword
        let methodPattern  = /^\s+(?:async\s+)?(\w+)\s*\([^)]*\)\s*(?::\s*\w+)?\s*\{/

        for (i, line) in lines.enumerated() {
            if let m = line.firstMatch(of: funcPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .function, filePath: path, line: i + 1))
            } else if let m = line.firstMatch(of: arrowPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .function, filePath: path, line: i + 1))
            } else if let m = line.firstMatch(of: classPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .class, filePath: path, line: i + 1))
            } else if let m = line.firstMatch(of: ifacePattern) {
                symbols.append(Symbol(name: String(m.1), kind: .interface, filePath: path, line: i + 1))
            } else if let m = line.firstMatch(of: typePattern) {
                symbols.append(Symbol(name: String(m.1), kind: .type, filePath: path, line: i + 1))
            } else if let m = line.firstMatch(of: methodPattern) {
                let name = String(m.1)
                // Skip common non-method keywords
                guard !["if", "for", "while", "switch", "catch"].contains(name) else { continue }
                symbols.append(Symbol(name: name, kind: .method, filePath: path, line: i + 1))
            }
        }
        return symbols
    }

    // MARK: - Rust

    private static func parseRust(_ src: String, path: String) -> [Symbol] {
        var symbols: [Symbol] = []
        let lines = src.components(separatedBy: "\n")

        let fnPattern     = /(?:pub\s+)?(?:async\s+)?fn\s+(\w+)\s*[<(]/
        let structPattern = /(?:pub\s+)?struct\s+(\w+)/
        let enumPattern   = /(?:pub\s+)?enum\s+(\w+)/
        let traitPattern  = /(?:pub\s+)?trait\s+(\w+)/
        let implPattern   = /impl(?:<[^>]+>)?\s+(\w+)/
        let typePattern   = /(?:pub\s+)?type\s+(\w+)\s*=/

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }

            if let m = trimmed.firstMatch(of: fnPattern) {
                let isMethod = line.hasPrefix("    ") // indented = inside impl
                symbols.append(Symbol(name: String(m.1), kind: isMethod ? .method : .function, filePath: path, line: i + 1))
            } else if let m = trimmed.firstMatch(of: structPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .struct, filePath: path, line: i + 1))
            } else if let m = trimmed.firstMatch(of: enumPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .enum, filePath: path, line: i + 1))
            } else if let m = trimmed.firstMatch(of: traitPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .trait, filePath: path, line: i + 1))
            } else if let m = trimmed.firstMatch(of: implPattern) {
                // impl blocks themselves aren't a symbol, but we track the type name for context
                _ = m // could annotate subsequent methods with impl context
            } else if let m = trimmed.firstMatch(of: typePattern) {
                symbols.append(Symbol(name: String(m.1), kind: .type, filePath: path, line: i + 1))
            }
        }
        return symbols
    }

    // MARK: - Go

    private static func parseGo(_ src: String, path: String) -> [Symbol] {
        var symbols: [Symbol] = []
        let lines = src.components(separatedBy: "\n")

        // func Foo( or func (r *Receiver) Foo(
        let methodPattern  = /^func\s+\(\w+\s+\*?(\w+)\)\s+(\w+)\s*\(/
        let funcPattern    = /^func\s+(\w+)\s*[<(]/
        let structPattern  = /^type\s+(\w+)\s+struct/
        let ifacePattern   = /^type\s+(\w+)\s+interface/
        let typePattern    = /^type\s+(\w+)\s+\w/

        for (i, line) in lines.enumerated() {
            if line.hasPrefix("//") { continue }

            if let m = line.firstMatch(of: methodPattern) {
                symbols.append(Symbol(name: String(m.2), kind: .method, filePath: path, line: i + 1,
                                      signature: "(\(m.1)) \(m.2)()"))
            } else if let m = line.firstMatch(of: structPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .struct, filePath: path, line: i + 1))
            } else if let m = line.firstMatch(of: ifacePattern) {
                symbols.append(Symbol(name: String(m.1), kind: .interface, filePath: path, line: i + 1))
            } else if let m = line.firstMatch(of: typePattern) {
                symbols.append(Symbol(name: String(m.1), kind: .type, filePath: path, line: i + 1))
            } else if let m = line.firstMatch(of: funcPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .function, filePath: path, line: i + 1))
            }
        }
        return symbols
    }
    
    // MARK: - Swift
    
    private static func parseSwift(_ src: String, path: String) -> [Symbol] {
        var symbols: [Symbol] = []
        let lines = src.components(separatedBy: "\n")

        let funcPattern   = /(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+)?(?:static\s+)?(?:async\s+)?func\s+(\w+)\s*[<(]/
        let classPattern  = /(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+)?(?:final\s+)?class\s+(\w+)/
        let structPattern = /(?:public\s+|private\s+|internal\s+|fileprivate\s+)?struct\s+(\w+)/
        let enumPattern   = /(?:public\s+|private\s+|internal\s+|fileprivate\s+)?enum\s+(\w+)/
        let protPattern   = /(?:public\s+|private\s+|internal\s+|fileprivate\s+)?protocol\s+(\w+)/
        let actorPattern  = /(?:public\s+|private\s+|internal\s+|fileprivate\s+)?actor\s+(\w+)/

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }

            if let m = trimmed.firstMatch(of: funcPattern) {
                let isMethod = line.hasPrefix("    ") || line.hasPrefix("\t")
                symbols.append(Symbol(name: String(m.1), kind: isMethod ? .method : .function, filePath: path, line: i + 1))
            } else if let m = trimmed.firstMatch(of: classPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .class, filePath: path, line: i + 1))
            } else if let m = trimmed.firstMatch(of: structPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .struct, filePath: path, line: i + 1))
            } else if let m = trimmed.firstMatch(of: enumPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .enum, filePath: path, line: i + 1))
            } else if let m = trimmed.firstMatch(of: protPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .trait, filePath: path, line: i + 1))
            } else if let m = trimmed.firstMatch(of: actorPattern) {
                symbols.append(Symbol(name: String(m.1), kind: .class, filePath: path, line: i + 1))
            }
        }
        return symbols
    }
}
