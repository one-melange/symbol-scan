import SwiftUI
import AppKit

/// The single source of truth for how SymbolScan *looks*.
///
/// Historically every color, font, corner radius, padding, and size was an inline literal at the
/// point it was used (see `STYLING.md`). They now live here, named by **role** (`statusHint`,
/// `cardBorder`) rather than by value, so a restyle is a one-line edit in one file and repeated
/// values can't drift apart.
///
/// Two house conventions the values encode:
/// - **Monospaced is the code font.** Symbol names, signatures, paths, badges, and the hotkey field
///   use `design: .monospaced`; prose (empty-state, settings copy) uses the default design.
/// - **Semantic colors + system materials do the theming.** The UI leans on `.primary`/`.secondary`/
///   `.tertiary`/`.quaternary`, `.ultraThinMaterial`, and `.bar` so the overlay adapts to
///   light/dark automatically. Only genuine literals (explicit opacities, the kind palette, the
///   card border/shadow) are hoisted here; bare semantic tokens stay inline at their call sites.
///
/// `Theme` is an uninstantiable namespace — reference its nested members directly
/// (`Theme.Radius.card`, `Theme.Fonts.rowName`, …).
enum Theme {

    // MARK: - Corner radii

    enum Radius {
        /// Picker card. Applied twice (clip shape + border overlay) — they must stay equal.
        static let card: CGFloat = 12
        /// Trigger badge and kind badge.
        static let badge: CGFloat = 4
        /// Custom-drawn hotkey recorder field (AppKit).
        static let recorder: CGFloat = 6
    }

    // MARK: - Stroke / line widths

    enum Stroke {
        /// Hairline border around the picker card.
        static let cardBorder: CGFloat = 1
        /// Recorder outline while idle.
        static let recorderIdle: CGFloat = 1
        /// Recorder outline while capturing a combo.
        static let recorderRecording: CGFloat = 1.5
    }

    // MARK: - Sizes / frames

    enum Metrics {
        /// Height of a single result row (drives the results-list frame math).
        static let rowHeight: CGFloat = 44
        /// The results list shows between this many rows (min) …
        static let visibleRowsMin = 5
        /// … and this many (max) before it scrolls.
        static let visibleRowsMax = 8
        /// Trailing breathing room added under the visible rows.
        static let listBottomPad: CGFloat = 8

        /// Kind badge is a square of this side.
        static let badgeSize: CGFloat = 20
        /// Height reserved for the AppKit-backed search field.
        static let searchFieldHeight: CGFloat = 20

        /// Divider drawn between the symbol count and the key hints in the status bar.
        static let statusDividerHeight: CGFloat = 10

        /// Explanation pane caps its scroll view at this height so a long answer can't grow the card.
        static let explanationMaxHeight: CGFloat = 150

        /// Hotkey settings pane width, and the reserved height of its "Saved" confirmation row.
        static let settingsPaneWidth: CGFloat = 380
        static let savedRowHeight: CGFloat = 16
        /// Click-to-record hotkey field (SwiftUI frame + AppKit `intrinsicContentSize`).
        static let recorderSize = NSSize(width: 130, height: 26)

        /// Documentation popover: fixed readable width, minimum height, and text insets.
        static let popoverWidth: CGFloat = 360
        static let popoverMinHeight: CGFloat = 40
        static let popoverInsetH: CGFloat = 12
        static let popoverInsetV: CGFloat = 10
    }

    // MARK: - Spacing (between stacked elements)

    enum Spacing {
        /// Root card `VStack` and the results `LazyVStack` — flush, no gaps.
        static let card: CGFloat = 0
        static let list: CGFloat = 0
        /// Search bar `HStack` (badge · field · spinner) and a symbol row `HStack`.
        static let searchBar: CGFloat = 10
        static let row: CGFloat = 10
        /// Name-over-signature and path-over-line stacks inside a row.
        static let rowText: CGFloat = 1
        /// Explanation pane `VStack` and its header `HStack`; the empty-state `VStack`.
        static let explanation: CGFloat = 6
        static let explanationHeader: CGFloat = 6
        static let emptyState: CGFloat = 6
        /// Status bar `HStack`.
        static let statusBar: CGFloat = 8
        /// Hotkey settings `VStack`.
        static let settings: CGFloat = 14
    }

    // MARK: - Padding

    enum Padding {
        static let searchBar = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        static let triggerBadge = EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)
        static let explanation = EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        static let statusBar = EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        static let row = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        /// Uniform pads.
        static let emptyState: CGFloat = 24
        static let settings: CGFloat = 20
    }

    // MARK: - Opacity (bare magnitudes reused across sites)

    enum Opacity {
        /// The hairline dividers inside the card.
        static let divider: Double = 0.3
        /// Accent wash behind the recorder while recording (AppKit `withAlphaComponent`).
        static let recorderRecordingFill: CGFloat = 0.15
    }

    // MARK: - Colors (SwiftUI)

    enum Colors {
        /// Hairline border around the card.
        static let cardBorder = Color.white.opacity(0.12)
        /// Drop shadow tint under the card.
        static let cardShadow = Color.black.opacity(0.4)
        /// Selected-row highlight wash.
        static let selection = Color.accentColor.opacity(0.15)
        /// Repo name + symbol count in the status bar.
        static let statusStrong = Color.primary.opacity(0.78)
        /// Keyboard-hint labels in the status bar.
        static let statusHint = Color.primary.opacity(0.68)
        /// Kind-badge glyph, drawn on the colored badge fill.
        static let badgeText = Color.white
        /// Explanation-pane error text.
        static let error = Color.red
        /// "Saved" confirmation in the hotkey settings.
        static let success = Color.green

        /// The kind badge palette — the live source of truth (replaces the old, unused
        /// `SymbolKind.color` that named non-existent asset colors).
        static func kind(_ kind: SymbolKind) -> Color {
            switch kind {
            case .function, .method:          return .blue
            case .class, .struct:             return .purple
            case .enum, .trait, .interface:   return .orange
            case .constant, .variable, .type: return .green
            case .file, .directory:           return .gray
            }
        }
    }

    // MARK: - Materials

    enum Materials {
        /// The visible frosted card surface (the window itself is clear).
        static let card: Material = .ultraThinMaterial
        /// Status bar background.
        static let statusBar: Material = .bar
        /// Trigger-badge fill.
        static let badgeFill: HierarchicalShapeStyle = .quaternary
    }

    // MARK: - Fonts

    enum Fonts {
        // SwiftUI — code-like text keeps `design: .monospaced`.
        static let triggerBadge = Font.system(size: 11, weight: .semibold, design: .monospaced)
        static let kindBadge = Font.system(size: 11, weight: .bold, design: .monospaced)
        static let rowName = Font.system(size: 13, weight: .medium, design: .monospaced)
        static let rowDetail = Font.system(size: 10, design: .monospaced)
        static let explanationHeader = Font.system(size: 11, weight: .semibold, design: .monospaced)

        static let statusLabel = Font.system(size: 11, weight: .semibold)
        static let statusCount = Font.system(size: 10, weight: .semibold)
        static let statusHint = Font.system(size: 10, weight: .medium)

        static let sparkles = Font.system(size: 11)
        static let explanationBody = Font.system(size: 12)
        static let emptyTitle = Font.system(size: 13)
        static let emptyHint = Font.system(size: 11)
        static let settingsRow = Font.system(size: 13)

        // AppKit.
        static let searchField = NSFont.systemFont(ofSize: 15, weight: .regular)
        static let popoverLabel = NSFont.systemFont(ofSize: 12)
        static let recorder = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    }

    // MARK: - Shadow (picker card)

    enum Shadow {
        static let radius: CGFloat = 24
        static let x: CGFloat = 0
        static let y: CGFloat = 8
    }

    // MARK: - Motion

    enum Motion {
        /// Selected-row highlight cross-fade.
        static let selection = Animation.easeInOut(duration: 0.08)
        /// Scroll-to-selection when the highlight moves.
        static let scroll = Animation.easeInOut(duration: 0.1)
    }

    // MARK: - Overlay window

    enum Window {
        /// Overlay size while showing just the picker …
        static let baseSize = NSSize(width: 520, height: 420)
        /// … and while the ⌘E explanation pane is open (so a streamed answer isn't clipped).
        static let expandedSize = NSSize(width: 520, height: 600)
        /// Gap between the screen's top edge and the top of the overlay.
        static let topMargin: CGFloat = 12
    }
}
