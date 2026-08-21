# STYLING.md

How to change how SymbolScan *looks*. This maps every place appearance is controlled, then gives
task-oriented recipes ("I want to change X → edit Y").

## Overview

SymbolScan is a SwiftUI overlay hosted in a transparent AppKit window. Every color, font, corner
radius, padding, and size lives in **one central theme file**:
`SymbolScan/SymbolScan/UI/Theme.swift`. The views and window read named members from it
(`Theme.Radius.card`, `Theme.Fonts.rowName`, `Theme.Window.baseSize`, …) instead of inline
literals, so a restyle is a one-line edit in one file and repeated values can't drift apart.

`Theme` is an uninstantiable `enum` namespace with nested enums grouped by concern:

| Namespace | Holds |
|---|---|
| `Theme.Radius` | corner radii — `card` (12), `badge` (4), `recorder` (6) |
| `Theme.Stroke` | line widths — card border, recorder idle/recording |
| `Theme.Metrics` | sizes/frames — `rowHeight`, visible-row bounds, badge size, popover width, recorder size, settings pane width, … |
| `Theme.Spacing` | stack spacings, by site |
| `Theme.Padding` | `EdgeInsets` (and uniform pads) by site |
| `Theme.Opacity` | bare opacity magnitudes (divider, recorder fill) |
| `Theme.Colors` | literal colors — card border/shadow, selection wash, status tints, badge text, error/success, and `kind(_:)` (the badge palette) |
| `Theme.Materials` | `card` (`.ultraThinMaterial`), `statusBar` (`.bar`), `badgeFill` (`.quaternary`) |
| `Theme.Fonts` | SwiftUI `Font` + AppKit `NSFont` for every text style |
| `Theme.Shadow` | the picker card's shadow radius/offset |
| `Theme.Motion` | the two `Animation`s (selection cross-fade, scroll) |
| `Theme.Window` | overlay `baseSize` / `expandedSize` / `topMargin` |

Two conventions run through the whole UI, encoded in the theme's values:

- **Monospaced is the house font.** Symbol names, signatures, paths, badges, and the hotkey field
  use `design: .monospaced` (`Theme.Fonts.rowName`, `.rowDetail`, `.kindBadge`, `.triggerBadge`,
  `.recorder`). Prose (empty-state, settings copy) uses the default design.
- **Semantic colors + system materials do the theming.** The UI leans on `.primary` / `.secondary`
  / `.tertiary` / `.quaternary`, `.ultraThinMaterial`, and `.bar` rather than fixed RGB values.
  That's why the overlay adapts to light/dark automatically — the window sets no `NSAppearance`.
  Only genuine literals are hoisted into `Theme`; **bare semantic tokens** (`.secondary`,
  `.tertiary`) and **AppKit system colors** (`labelColor`, `controlAccentColor`, `separatorColor`,
  `controlBackgroundColor`, `systemRed`) stay inline at their call sites — they're roles, not
  values. **Preserve semantic colors when restyling** and you keep dark-mode support for free.

## Component map

Appearance is set in three places: `Theme.swift` (the values), `UI/SymbolPickerView.swift` (almost
all the views that reference them), and `App/OverlayWindow.swift` (the window frame). The kind badge
glyphs live in `Index/Symbol.swift`.

| What you see | View · symbol | Theme members it reads |
|---|---|---|
| Picker "card": blur, corner radius, border, shadow | `UI/SymbolPickerView.swift` · `SymbolPickerView.body` | `Materials.card`, `Radius.card`, `Colors.cardBorder`+`Stroke.cardBorder`, `Colors.cardShadow`+`Shadow.*` |
| Search bar: hotkey badge, text field, spinner | same file · `searchBar` + `SearchFieldRepresentable` | `Fonts.triggerBadge`, `Materials.badgeFill`, `Radius.badge`, `Padding.triggerBadge`; field `Fonts.searchField` |
| Results list sizing / scroll behavior | same file · `resultsList` | `Metrics.rowHeight`, `Metrics.visibleRowsMin/Max`, `Metrics.listBottomPad`, `Motion.scroll` |
| **Symbol row**: badge, name, signature, path, selection highlight | same file · `SymbolRow` | `Fonts.kindBadge`/`.rowName`/`.rowDetail`, `Colors.badgeText`, `Metrics.badgeSize`, `Radius.badge`, `Padding.row`, `Colors.selection`, `Motion.selection` |
| **Kind badge colors** | `Theme.swift` · `Theme.Colors.kind(_:)` | the `.blue/.purple/.orange/.green/.gray` palette, keyed by `SymbolKind` |
| Explanation pane (⌘E) | `SymbolPickerView.swift` · `explanationPane` | `Fonts.explanationHeader`/`.explanationBody`/`.sparkles`, `Colors.error`, `Metrics.explanationMaxHeight`, `Padding.explanation` |
| Status / keyboard-hint bar | same file · `statusBar` | `Fonts.statusLabel`/`.statusCount`/`.statusHint`, `Colors.statusStrong`/`.statusHint`, `Materials.statusBar`, `Padding.statusBar` |
| Empty state | same file · `emptyState` | `Fonts.emptyTitle`/`.emptyHint`, `Spacing.emptyState`, `Padding.emptyState`; strings from `PickerEmptyState` |
| Doc popover (hover docs) | same file · `DocumentationPopoverViewController` | `Fonts.popoverLabel`, `Metrics.popoverWidth`/`.popoverMinHeight`/`.popoverInsetH`/`.popoverInsetV` |
| Hotkey settings pane | same file · `HotkeySettingsView` | `Spacing.settings`, `Padding.settings`, `Metrics.settingsPaneWidth`, `Fonts.settingsRow`, `Colors.success` |
| Key-recorder field (custom-drawn) | same file · `KeyRecorderNSView.draw` | `Radius.recorder`, `Metrics.recorderSize`, `Stroke.recorder*`, `Opacity.recorderRecordingFill`, `Fonts.recorder` |
| Overlay **window**: size, position | `App/OverlayWindow.swift` · `OverlayWindowController`, `OverlayPlacement` | `Window.baseSize`, `Window.expandedSize`, `Window.topMargin` |
| **Kind badge glyphs** | `Index/Symbol.swift` · `SymbolKind.icon` | single-char badge letters (`ƒ`, `C`, `S`, …) |
| Accent color + app icon | `Assets.xcassets/` | `AccentColor.colorset` (empty → system default); `AppIcon.appiconset/icon.png` |
| Menu-bar icon + preferences window chrome | `App/AppDelegate.swift` | SF Symbol `"curlybraces.square"`; prefs window `380×220`, title "SymbolScan Hotkeys" |
| App-icon regeneration | `scripts/update-icon.sh` | rebuilds the icon set from a source image |

> The visible frosted card — its material, rounded corners, hairline border, and drop shadow — is
> drawn by **SwiftUI**, not the window. `OverlayWindow` is intentionally transparent
> (`backgroundColor = .clear`) and shadowless (`hasShadow = false`); it only provides a borderless,
> floating, key-capable surface for the SwiftUI content. Those window flags are behavioral, so they
> live in `OverlayWindow.init`, not in `Theme`.

## How-to recipes

### Change the picker background / blur
`Theme.Materials.card` (default `.ultraThinMaterial`). Swap for another `Material`
(`.regularMaterial`, `.thickMaterial`, …) or a solid `Color`. The window stays clear, so whatever
this resolves to *is* the visible surface.

### Change corner radius, border, or shadow
`Theme.Radius.card` (the card clip **and** its overlay border both read it, so they stay equal),
`Theme.Colors.cardBorder` + `Theme.Stroke.cardBorder`, and `Theme.Colors.cardShadow` +
`Theme.Shadow.*`.

### Change the selection-highlight color
Two options:
- **Quick:** edit `Theme.Colors.selection` (default `Color.accentColor.opacity(0.15)`).
- **App-wide accent:** give `Assets.xcassets/AccentColor.colorset` a real color. It's currently
  empty, so `Color.accentColor` resolves to the macOS system accent; setting it recolors the
  highlight (and anything else using the accent) without touching code.

### Change the kind badge colors
Edit `Theme.Colors.kind(_:)` in `Theme.swift` — the single source of truth for the palette, keyed
by `SymbolKind`.

### Change the kind badge glyphs
Edit `SymbolKind.icon` in `Index/Symbol.swift` (e.g. swap the single letters for SF Symbols — you'd
then also change the badge from `Text(...)` to `Image(systemName:)` in `SymbolRow`).

### Change fonts / text sizes
Edit the relevant member of `Theme.Fonts`. SwiftUI text styles are `Font` values (`rowName`,
`rowDetail`, `statusHint`, …); the AppKit sites use `NSFont` values (`searchField`, `popoverLabel`,
`recorder`). Keep `design: .monospaced` on code-like text to match the house style.

### Change row height or how many rows show
`Theme.Metrics.rowHeight` sets row height; `Theme.Metrics.visibleRowsMin` / `.visibleRowsMax`
(currently 5–8) set the visible window, consumed by the `resultsList` frame math.

### Change the overlay window size or position
`Theme.Window.baseSize` / `Theme.Window.expandedSize` (the expanded one is used while the ⌘E
explanation pane is open). For placement, `Theme.Window.topMargin` (default 12) is how far below the
screen's top edge the overlay is pinned; `OverlayPlacement.frame(...)` centers it horizontally.

### Change the status / hint bar look
`Theme.Materials.statusBar` (background) and `Theme.Colors.statusStrong` / `.statusHint` (the label
tints), plus `Theme.Fonts.statusLabel` / `.statusCount` / `.statusHint`. The keyboard hints
(↵ inject, ⇥ copy, …) are rendered by a `ForEach` in `statusBar`.

### Change the menu-bar icon
`App/AppDelegate.swift` → `statusItem.button?.image = NSImage(systemSymbolName: "curlybraces.square",
…)`. Any SF Symbol name works; it renders as a monochrome template image.

### Change the app icon
Replace the source image and run `scripts/update-icon.sh`, which regenerates
`Assets.xcassets/AppIcon.appiconset`.

## Conventions & gotchas

- **Keep semantic colors for free dark mode.** The overlay sets no `NSAppearance`; it inherits the
  system appearance and relies on `.ultraThinMaterial`, `.bar`, and `.primary`/`.secondary`/… to
  adapt. `Theme` deliberately leaves bare semantic tokens and AppKit system colors inline; replacing
  those with fixed colors means you own light/dark yourself.
- **Some pieces are AppKit, not SwiftUI.** `KeyRecorderNSView.draw` and the documentation popover
  (`DocumentationPopoverViewController`) style with `NSColor`/`NSFont`. They read `NSFont` values and
  metrics from `Theme` but keep their semantic `NSColor`s (accent/separator/label) at the call site.
- **The window's chrome is SwiftUI's.** Don't try to add rounded corners or a shadow on
  `OverlayWindow` — it's transparent and shadowless on purpose; adjust the SwiftUI `body` (and the
  `Theme` members it reads) instead.
- **Add new values to `Theme`, don't inline them.** When you introduce a new styled element, give
  its color/font/metric a role-named member in `Theme.swift` and reference it, so the single-source-
  of-truth invariant holds.
