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

    @Test func facadeReturnsSymbolsForKnownSource() {
        // SymbolParser tries Tree-sitter, then RegexParser — either way this must yield the symbol.
        let s = SymbolParser.parse(source: "func hello() {}", language: .swift, path: "f")
        #expect(s.contains { $0.name == "hello" && $0.kind == .function })
    }
}
