import Testing
import Foundation
import CoreGraphics
@testable import SymbolScan

@Suite struct OverlayPlacementTests {

    private let size = NSSize(width: 520, height: 420)

    @Test func centeredAndTopPinnedOnZeroOriginScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1728, height: 1080)
        let f = OverlayPlacement.frame(in: visible, size: size)

        #expect(f.midX == visible.midX)                 // horizontally centered
        #expect(f.maxY == visible.maxY - 12)            // pinned 12pt below the top
        #expect(f.size.width == size.width && f.size.height == size.height)
    }

    /// Regression: a secondary monitor has a non-zero global origin. The old math used the
    /// screen's size but dropped its origin, shoving the overlay off to the side of external
    /// displays.
    @Test func staysOnScreenWithNonZeroOrigin() {
        let visible = NSRect(x: 1728, y: 0, width: 3440, height: 1415)
        let f = OverlayPlacement.frame(in: visible, size: size)

        #expect(visible.contains(f))                    // fully inside that screen
        #expect(f.midX == visible.midX)                 // centered on *its* midX, not global 0
        #expect(f.minX > visible.minX)                  // nothing cut off at the left edge
    }

    @Test func customTopMarginRespected() {
        let visible = NSRect(x: 0, y: 0, width: 2000, height: 1000)
        let f = OverlayPlacement.frame(in: visible, size: size, topMargin: 40)
        #expect(f.maxY == visible.maxY - 40)
    }

    /// Negative-origin arrangements exist too (a display positioned left of/below the main one).
    @Test func negativeOriginScreen() {
        let visible = NSRect(x: -2560, y: -300, width: 2560, height: 1415)
        let f = OverlayPlacement.frame(in: visible, size: size)
        #expect(visible.contains(f))
        #expect(f.midX == visible.midX)
    }
}
