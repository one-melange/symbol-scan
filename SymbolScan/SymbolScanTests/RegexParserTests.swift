import Foundation
import Testing
@testable import SymbolScan

/// Exercises the per-language symbol extractors via the `parse(source:language:path:)` seam,
/// so no temp files are needed. Source is built with explicit "\n" joins to keep indentation
/// exact (Swift multiline literals re-indent relative to the closing delimiter).
@Suite struct RegexParserTests {

    private func parse(_ lines: [String], _ lang: Language) -> [Symbol] {
        RegexParser.parse(source: lines.joined(separator: "\n"), language: lang, path: "f")
    }

    @Test func python() {
        let s = parse([
            "def top_level(a, b):",
            "    pass",
            "",
            "class Foo:",
            "    def method(self):",
            "        pass",
        ], .python)
        #expect(s.contains { $0.name == "top_level" && $0.kind == .function && $0.line == 1 })
        #expect(s.contains { $0.name == "Foo" && $0.kind == .class && $0.line == 4 })
        #expect(s.contains { $0.name == "method" && $0.kind == .method && $0.line == 5 })
    }

    @Test func typescript() {
        let s = parse([
            "export function doThing<T>(x: number) {}",
            "const arrow = async (y) => {}",
            "export class Widget {}",
            "interface Shape {}",
            "type Alias = string",
            "class C {",
            "    render(): void {}",
            "    if (x) {}",
            "}",
        ], .typescript)
        #expect(s.contains { $0.name == "doThing" && $0.kind == .function })
        #expect(s.contains { $0.name == "arrow"   && $0.kind == .function })
        #expect(s.contains { $0.name == "Widget"  && $0.kind == .class })
        #expect(s.contains { $0.name == "Shape"   && $0.kind == .interface })
        #expect(s.contains { $0.name == "Alias"   && $0.kind == .type })
        #expect(s.contains { $0.name == "render"  && $0.kind == .method })
        #expect(!s.contains { $0.name == "if" })   // control-flow keyword is skipped
    }

    @Test func rust() {
        let s = parse([
            "pub fn free_fn() {}",
            "struct Point {}",
            "enum Color {}",
            "trait Drawable {}",
            "type Alias = u32;",
            "impl Point {",
            "    fn method(&self) {}",
            "}",
            "// fn commented() {}",
        ], .rust)
        #expect(s.contains { $0.name == "free_fn"  && $0.kind == .function })
        #expect(s.contains { $0.name == "Point"    && $0.kind == .struct })
        #expect(s.contains { $0.name == "Color"    && $0.kind == .enum })
        #expect(s.contains { $0.name == "Drawable" && $0.kind == .trait })
        #expect(s.contains { $0.name == "Alias"    && $0.kind == .type })
        #expect(s.contains { $0.name == "method"   && $0.kind == .method })
        #expect(!s.contains { $0.name == "commented" })  // comment line skipped
    }

    @Test func go() {
        let s = parse([
            "func FreeFunc() {}",
            "func (r *Receiver) Method() {}",
            "type Point struct {",
            "type Reader interface {",
            "type Alias int",
        ], .go)
        #expect(s.contains { $0.name == "FreeFunc" && $0.kind == .function })
        #expect(s.contains { $0.name == "Method"   && $0.kind == .method })
        #expect(s.contains { $0.name == "Point"    && $0.kind == .struct })
        #expect(s.contains { $0.name == "Reader"   && $0.kind == .interface })
        #expect(s.contains { $0.name == "Alias"    && $0.kind == .type })
    }

    @Test func swift() {
        let s = parse([
            "func freeFunc() {}",
            "public class MyClass {}",
            "struct MyStruct {}",
            "enum MyEnum {}",
            "protocol MyProto {}",
            "actor MyActor {}",
            "    func indentedMethod() {}",
            "// func commented() {}",
        ], .swift)
        #expect(s.contains { $0.name == "freeFunc"       && $0.kind == .function })
        #expect(s.contains { $0.name == "MyClass"        && $0.kind == .class })
        #expect(s.contains { $0.name == "MyStruct"       && $0.kind == .struct })
        #expect(s.contains { $0.name == "MyEnum"         && $0.kind == .enum })
        #expect(s.contains { $0.name == "MyProto"        && $0.kind == .trait })   // protocol → trait
        #expect(s.contains { $0.name == "MyActor"        && $0.kind == .class })   // actor → class
        #expect(s.contains { $0.name == "indentedMethod" && $0.kind == .method })
        #expect(!s.contains { $0.name == "commented" })
    }

    @Test func emptySourceYieldsNothing() {
        #expect(RegexParser.parse(source: "", language: .swift, path: "f").isEmpty)
    }

    /// The URL overload must stamp symbols with the caller-supplied relative path — not the
    /// bare filename (regression for T2: path-truncation / dead `relPath`).
    @Test func urlOverloadThreadsRelativePath() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SymbolScanTest-\(UUID().uuidString).swift")
        try "func hello() {}".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let relativePath = "a/b/c.swift"
        let symbols = try RegexParser.parse(url: tmp, language: .swift, relativePath: relativePath)

        #expect(!symbols.isEmpty)
        #expect(symbols.allSatisfy { $0.filePath == relativePath })
    }
}
