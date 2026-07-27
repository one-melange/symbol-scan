import Foundation
import Testing
@testable import SymbolScan

/// Exercises the Tree-sitter extractor (T16) via the pure `parse(source:language:path:)` seam —
/// no temp files. Source is built with explicit "\n" joins so indentation/line numbers are exact.
/// Focuses on cases the old regex extractor got wrong: method-vs-function by real nesting, Go
/// struct/interface/alias distinction, Rust impl methods, TS arrow consts, Swift struct/enum/actor.
@Suite struct TreeSitterParserTests {

    private func parse(_ lines: [String], _ lang: Language) throws -> [Symbol] {
        try #require(TreeSitterParser.parse(source: lines.joined(separator: "\n"), language: lang, path: "f"))
    }

    private func has(_ s: [Symbol], _ name: String, _ kind: SymbolKind, _ line: Int? = nil) -> Bool {
        s.contains { $0.name == name && $0.kind == kind && (line == nil || $0.line == line) }
    }

    @Test func python() throws {
        let s = try parse([
            "def top_level(a, b):",
            "    pass",
            "",
            "class Foo:",
            "    def method(self):",
            "        pass",
        ], .python)
        #expect(has(s, "top_level", .function, 1))
        #expect(has(s, "Foo", .class, 4))
        #expect(has(s, "method", .method, 5))
    }

    @Test func pythonNestedFunctionIsNotAMethod() throws {
        let s = try parse([
            "def outer():",
            "    def inner():",
            "        pass",
        ], .python)
        // `inner` is nested in a function, not a class → function, not method (regex got this wrong).
        #expect(has(s, "outer", .function))
        #expect(has(s, "inner", .function))
        #expect(!has(s, "inner", .method))
    }

    @Test func go() throws {
        let s = try parse([
            "package main",
            "",
            "type Point struct {",
            "\tX int",
            "}",
            "",
            "type Shape interface {",
            "\tArea() float64",
            "}",
            "",
            "type ID string",
            "",
            "func Free() {}",
            "",
            "func (p Point) Move() {}",
        ], .go)
        #expect(has(s, "Point", .struct))
        #expect(has(s, "Shape", .interface))
        #expect(has(s, "ID", .type))
        #expect(has(s, "Free", .function))
        #expect(has(s, "Move", .method))
    }

    @Test func rust() throws {
        let s = try parse([
            "pub fn free_fn() {}",
            "",
            "struct MyStruct;",
            "",
            "enum MyEnum {}",
            "",
            "trait MyTrait {}",
            "",
            "type Alias = u32;",
            "",
            "impl MyStruct {",
            "    fn method(&self) {}",
            "}",
        ], .rust)
        #expect(has(s, "free_fn", .function))
        #expect(has(s, "MyStruct", .struct))
        #expect(has(s, "MyEnum", .enum))
        #expect(has(s, "MyTrait", .trait))
        #expect(has(s, "Alias", .type))
        #expect(has(s, "method", .method))   // inside impl → method, not function
    }

    @Test func typescript() throws {
        let s = try parse([
            "export function doThing<T>(x: number) {}",
            "",
            "export const arrow = (y: number) => y + 1;",
            "",
            "class Widget {",
            "    render(): void {}",
            "}",
            "",
            "interface Props {}",
            "",
            "type Alias = string;",
        ], .typescript)
        #expect(has(s, "doThing", .function))
        #expect(has(s, "arrow", .function))
        #expect(has(s, "Widget", .class))
        #expect(has(s, "render", .method))
        #expect(has(s, "Props", .interface))
        #expect(has(s, "Alias", .type))
    }

    @Test func tsx() throws {
        let s = try parse([
            "export function App(): JSX.Element {",
            "    return <div className=\"x\">hi</div>;",
            "}",
            "",
            "export const Button = (p: Props) => <button onClick={p.on} />;",
            "",
            "interface Props { on: () => void }",
            "",
            "class Panel {",
            "    render() { return <p />; }",
            "}",
        ], .tsx)
        #expect(has(s, "App", .function, 1))
        #expect(has(s, "Button", .function, 5))
        #expect(has(s, "Props", .interface, 7))
        #expect(has(s, "Panel", .class, 9))
        #expect(has(s, "render", .method, 10))
    }

    /// The T20 bug: `.tsx` was routed to the plain TypeScript grammar, which can't parse JSX.
    /// Tree-sitter error-recovers rather than failing, so no fallback ever fired — symbols just
    /// silently disappeared. Asserted as "strictly fewer" rather than an exact count so future
    /// grammar-recovery improvements don't make this brittle.
    @Test func jsxUnderThePlainTypeScriptGrammarLosesSymbols() throws {
        let src = [
            "export const Button = () => <button />;",
            "export function App() { return <div><Button /></div>; }",
        ]
        let tsx = try parse(src, .tsx)
        let ts  = try parse(src, .typescript)
        #expect(tsx.count > ts.count)
        #expect(has(tsx, "Button", .function))
        #expect(has(tsx, "App", .function))
    }

    @Test func javascript() throws {
        let s = try parse([
            "export function doThing(x) {}",
            "",
            "export const arrow = (y) => y + 1;",
            "",
            "const legacy = function () {};",
            "",
            "function* gen() {}",
            "",
            "class Widget {",
            "    render() {}",
            "    #secret() {}",
            "}",
        ], .javascript)
        #expect(has(s, "doThing", .function, 1))
        #expect(has(s, "arrow", .function, 3))
        #expect(has(s, "legacy", .function, 5))
        #expect(has(s, "gen", .function, 7))
        #expect(has(s, "Widget", .class, 9))    // JS names classes (identifier), TS (type_identifier)
        #expect(has(s, "render", .method, 10))
        // `private_property_identifier` spans the `#`, so that's the indexed name. Search is
        // substring, so a query of "secret" still finds it.
        #expect(has(s, "#secret", .method, 11))
    }

    /// Unlike TS/TSX, JSX is native to the JavaScript grammar — `.jsx` needs no separate dialect.
    @Test func jsxInPlainJavaScriptNeedsNoSeparateGrammar() throws {
        let s = try parse([
            "export const Card = ({ t }) => <div className=\"c\">{t}</div>;",
            "export function List() { return <ul><Card t=\"a\" /></ul>; }",
        ], .javascript)
        #expect(has(s, "Card", .function, 1))
        #expect(has(s, "List", .function, 2))
    }

    @Test func swift() throws {
        let s = try parse([
            "func freeFunc() {}",
            "",
            "struct MyStruct {",
            "    func method() {}",
            "}",
            "",
            "class MyClass {}",
            "",
            "enum MyEnum {}",
            "",
            "actor MyActor {}",
            "",
            "protocol MyProto {}",
            "",
            "typealias MyAlias = Int",
        ], .swift)
        #expect(has(s, "freeFunc", .function))
        #expect(has(s, "MyStruct", .struct))
        #expect(has(s, "method", .method))    // inside struct → method
        #expect(has(s, "MyClass", .class))
        #expect(has(s, "MyEnum", .enum))
        #expect(has(s, "MyActor", .class))    // actor maps to .class, as in RegexParser
        #expect(has(s, "MyProto", .trait))    // protocol maps to .trait
        #expect(has(s, "MyAlias", .type))
    }

    // MARK: - Signatures (T21)

    @Test func goMethodSignatureCarriesTheReceiverType() throws {
        let s = try parse([
            "package main",
            "",
            "type Server struct{}",
            "type Conn struct{}",
            "",
            "func (s *Server) Close() {}",
            "func (c Conn) Close() {}",
        ], .go)
        // Two same-named methods on different receivers: the signature is the only thing that
        // tells them apart in the picker.
        let closes = s.filter { $0.name == "Close" }
        #expect(closes.count == 2)
        #expect(closes.contains { $0.signature == "(*Server) Close" })
        #expect(closes.contains { $0.signature == "(Conn) Close" })
    }

    @Test func nonGoSymbolsHaveNoSignature() throws {
        let swift = try parse(["func hello() {}"], .swift)
        #expect(swift.first { $0.name == "hello" }?.signature == nil)
        let go = try parse(["package main", "func Free() {}"], .go)
        #expect(go.first { $0.name == "Free" }?.signature == nil)   // plain func, no receiver
    }

    // MARK: - Facade / grammar health

    /// Every dialect must produce a buildable grammar *and* a compilable query. `parse` returns nil
    /// only on a build failure, so this catches a query referencing a node type its grammar doesn't
    /// have — which, since T21 removed the regex fallback, would otherwise just mean "that language
    /// silently indexes nothing".
    @Test func everyDialectBuildsAGrammarAndQuery() {
        for lang in Language.allCases {
            #expect(TreeSitterParser.parse(source: "", language: lang, path: "f") != nil,
                    "no grammar/query for \(lang.rawValue)")
        }
    }

    // MARK: - Minified-source guard (T8)

    @Test func minifiedSourceIsSkipped() {
        // One long line of mangled declarations, as a bundler emits.
        let bundle = (0..<400).map { "function m\($0)(a,b){return a+b}" }.joined()
        #expect(bundle.count > SymbolParser.minifiedLineThreshold)
        #expect(SymbolParser.isMinified(bundle))
        #expect(SymbolParser.parse(source: bundle, language: .javascript, path: "index-DJ7HgGZS.js").isEmpty)
    }

    @Test func ordinarySourceIsNotTreatedAsMinified() {
        // Same total size, but split across lines — length alone must not trip the guard.
        let normal = (0..<400).map { "function m\($0)(a, b) { return a + b; }" }.joined(separator: "\n")
        #expect(normal.count > SymbolParser.minifiedLineThreshold)
        #expect(!SymbolParser.isMinified(normal))
        #expect(SymbolParser.parse(source: normal, language: .javascript, path: "app.js").count == 400)
    }

    /// A long *trailing* line with no terminating newline must still trip the guard.
    @Test func minifiedDetectionHandlesUnterminatedFinalLine() {
        let source = "// header\n" + String(repeating: "x", count: SymbolParser.minifiedLineThreshold + 1)
        #expect(SymbolParser.isMinified(source))
    }

    @Test func facadeReturnsSymbolsForKnownSource() {
        // Tree-sitter is the only extractor now (T21) — the facade just unwraps and warns on a
        // grammar-build failure.
        let s = SymbolParser.parse(source: "func hello() {}", language: .swift, path: "f")
        #expect(s.contains { $0.name == "hello" && $0.kind == .function })
    }
}
