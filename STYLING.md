# STYLING.md

How to change how SymbolScan *looks*. This maps every place appearance is controlled, then gives
task-oriented recipes ("I want to change X → edit Y").

## Overview

SymbolScan is a SwiftUI overlay hosted in a transparent AppKit window. **All styling is inline** —
SwiftUI view modifiers and a few AppKit `draw`/property calls. There is deliberately **no central
`Theme`/`Constants`/`Style` file**: every color, font, corner radius, padding, and size is a literal
at the point it's used.

Two conventions run through the whole UI:

- **Monospaced is the house font.** Symbol names, signatures, paths, badges, and the hotkey field
  all use `.font(.system(..., design: .monospaced))`. Prose (empty-state, settings copy) uses the
  default design.
- **Semantic colors + system materials do the theming.** The UI leans on `.primary` / `.secondary`
  / `.tertiary` / `.quaternary`, `.ultraThinMaterial`, and `.bar` rather than fixed RGB values.
  That's why the overlay adapts to light/dark automatically — the window sets no `NSAppearance`.
  **Preserve semantic colors when restyling** and you keep dark-mode support for free.

## Component map

Almost everything visible lives in one file: `SymbolScan/SymbolScan/UI/SymbolPickerView.swift`.

| What you see | File · symbol | Notes |
|---|---|---|
| Picker "card": blur, corner radius, border, shadow | `UI/SymbolPickerView.swift` · `SymbolPickerView.body` | `.background(.ultraThinMaterial)`, `RoundedRectangle(cornerRadius: 12)`, `.stroke(Color.white.opacity(0.12))`, `.shadow(radius: 24, y: 8)` |
| Search bar: hotkey badge, text field, spinner | same file · `searchBar` + `SearchFieldRepresentable` | badge is monospaced size-11 on `.quaternary`; field font `systemFont(ofSize: 15)` |
| Results list sizing / scroll behavior | same file · `resultsList` + `rowHeight` const | `rowHeight = 44`; list shows 5–8 rows via the `maxHeight` expression |
| **Symbol row**: badge, name, signature, path, selection highlight | same file · `SymbolRow` | monospaced text; highlight `Color.accentColor.opacity(0.15)` |
| **Kind badge colors** (what actually renders) | same file · `SymbolRow.kindColor` | hardcoded `.blue/.purple/.orange/.green/.gray` |
| Explanation pane (⌘E) | same file · `explanationPane` | fonts, `maxHeight: 150`, error text `Color.red` |
| Status / keyboard-hint bar | same file · `statusBar` | `.background(.bar)`, `.primary.opacity(...)` tints |
| Empty state | same file · `emptyState` | `.secondary` / `.tertiary`; strings from `PickerEmptyState` |
| Doc popover (hover docs) | same file · `DocumentationPopoverViewController` | AppKit `NSTextField`, `systemFont(ofSize: 12)`, width 360 |
| Hotkey settings pane | same file · `HotkeySettingsView` | `.padding(20)`, `.frame(width: 380)` |
| Key-recorder field (custom-drawn) | same file · `KeyRecorderNSView.draw` | AppKit `NSColor.controlAccentColor` / `.separatorColor`, radius 6 |
| Overlay **window**: transparency, level, size, position | `App/OverlayWindow.swift` · `OverlayWindow`, `OverlayWindowController`, `OverlayPlacement` | borderless, `.floating`, clear + shadowless; sizes `baseSize` / `expandedSize`; `topMargin: 12` |
| **Kind badge glyphs** | `Index/Symbol.swift` · `SymbolKind.icon` | single-char badge letters (`ƒ`, `C`, `S`, …) |
| Accent color + app icon | `Assets.xcassets/` | `AccentColor.colorset` (empty → system default); `AppIcon.appiconset/icon.png` |
| Menu-bar icon + preferences window chrome | `App/AppDelegate.swift` | SF Symbol `"curlybraces.square"`; prefs window `380×220`, title "SymbolScan Hotkeys" |
| App-icon regeneration | `scripts/update-icon.sh` | rebuilds the icon set from a source image |

> The visible frosted card — its material, rounded corners, hairline border, and drop shadow — is
> drawn by **SwiftUI**, not the window. `OverlayWindow` is intentionally transparent
> (`backgroundColor = .clear`) and shadowless (`hasShadow = false`); it only provides a borderless,
> floating, key-capable surface for the SwiftUI content.

## How-to recipes

### Change the picker background / blur
`SymbolPickerView.body` → the `.background(.ultraThinMaterial)` modifier. Swap for another
`Material` (`.regularMaterial`, `.thickMaterial`, …) or a solid `Color`. The window stays clear, so
whatever you put here *is* the visible surface.

### Change corner radius, border, or shadow
Same `body` block. Corner radius appears **twice** — the `.clipShape` and the `.overlay` stroke —
keep them equal. The border is `Color.white.opacity(0.12)`; the shadow is `.shadow(color:
.black.opacity(0.4), radius: 24, x: 0, y: 8)`.

### Change the selection-highlight color
Two options:
- **Quick:** edit `SymbolRow` → `.background(isSelected ? Color.accentColor.opacity(0.15) : .clear)`.
- **App-wide accent:** give `Assets.xcassets/AccentColor.colorset` a real color. It's currently
  empty, so `Color.accentColor` resolves to the macOS system accent; setting it recolors the
  highlight (and anything else using the accent) without touching code.

### Change the kind badge colors
Edit `SymbolRow.kindColor` in `UI/SymbolPickerView.swift`. ⚠️ **Do not** edit `SymbolKind.color` in
`Index/Symbol.swift` — see [Gotchas](#conventions--gotchas); it is dead code and has no effect on
what renders.

### Change the kind badge glyphs
Edit `SymbolKind.icon` in `Index/Symbol.swift` (e.g. swap the single letters for SF Symbols — you'd
then also change the badge from `Text(...)` to `Image(systemName:)` in `SymbolRow`).

### Change fonts / text sizes
Fonts are per-view `.font(.system(size:weight:design:))` calls throughout
`UI/SymbolPickerView.swift`. Key ones: row name size 13, signature/path size 10, status bar size
10, search field 15 (in `SearchFieldRepresentable.makeNSView`). Keep `design: .monospaced` on
code-like text to match the house style.

### Change row height or how many rows show
`rowHeight` (const, top of `SymbolPickerView`) sets row height; the `resultsList` `.frame(minHeight:
maxHeight:)` expression sets the visible window (currently 5–8 rows).

### Change the overlay window size or position
`App/OverlayWindow.swift`: `OverlayWindowController.baseSize` / `expandedSize` (the expanded one is
used while the ⌘E explanation pane is open). For placement, `OverlayPlacement.frame(...)` centers
horizontally and pins `topMargin` (default 12) below the screen's top edge.

### Change the status / hint bar look
`statusBar` in `UI/SymbolPickerView.swift` — `.background(.bar)` and the `.primary.opacity(0.68–
0.78)` tints on the labels. The keyboard hints (↵ inject, ⇥ copy, …) are plain `Text` here.

### Change the menu-bar icon
`App/AppDelegate.swift` → `statusItem.button?.image = NSImage(systemSymbolName: "curlybraces.square",
…)`. Any SF Symbol name works; it renders as a monochrome template image.

### Change the app icon
Replace the source image and run `scripts/update-icon.sh`, which regenerates
`Assets.xcassets/AppIcon.appiconset`.

## Conventions & gotchas

- **`SymbolKind.color` is dead code.** In `Index/Symbol.swift`, `SymbolKind.color` returns asset
  names (`"symbolFunc"`, `"symbolType"`, …) with a comment saying to define them in the catalog —
  but **those color sets don't exist and nothing references the property.** The live badge colors
  are the hardcoded `kindColor` switch in `SymbolRow`. If you want to unify them: add the named
  color sets to `Assets.xcassets`, then change `SymbolRow.kindColor` to
  `Color(symbol.kind.color)`.
- **Keep semantic colors for free dark mode.** The overlay sets no `NSAppearance`; it inherits the
  system appearance and relies on `.ultraThinMaterial`, `.bar`, and `.primary`/`.secondary`/… to
  adapt. Replacing those with fixed colors means you own light/dark yourself.
- **Some pieces are AppKit, not SwiftUI.** `KeyRecorderNSView.draw` and the documentation popover
  (`DocumentationPopoverViewController`) style with `NSColor`/`NSFont`, not SwiftUI `Color`/`Font`.
  Style them there, in their `draw`/`loadView` methods.
- **The window's chrome is SwiftUI's.** Don't try to add rounded corners or a shadow on
  `OverlayWindow` — it's transparent and shadowless on purpose; adjust the SwiftUI `body` instead.

## Want a central theme?

There isn't one today — every value is an inline literal. If the styling grows, the natural
refactor is to hoist the repeated literals (corner radius 12, the badge palette, the
`.primary.opacity(...)` tints, the row/window sizes) into a single `Theme`/`Style` type and
reference it from the views. Until then, this doc is the index of where each value lives.
