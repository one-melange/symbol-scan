import Testing
import AppKit
@testable import SymbolScan

@Suite struct TextInjectorTests {

    /// `inject` posts real system keyboard events (needs Accessibility), so it isn't unit
    /// tested. `copyToClipboard` is pure pasteboard work and is verified here, restoring the
    /// user's clipboard afterward.
    @Test func copyToClipboardWritesString() {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
        TextInjector.copyToClipboard("symbolName")
        #expect(pb.string(forType: .string) == "symbolName")
    }
}
