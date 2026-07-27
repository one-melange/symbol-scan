# AGENTS.md

Guidance for Codex (and humans) working in this repo.

## What it is

SymbolScan is a macOS menu-less (`.accessory`) overlay app that helps devs reference code
symbols while prompting AI coding tools. A global hotkey pops a transparent picker, you
fuzzy-search symbols indexed from the current git repo, and the chosen symbol is injected
into whatever app had focus (or copied to the clipboard).

Triggers (`Input/EventTap.swift`, currently hardcoded):
- `@` — intended for Codex
- `#` — intended for Codex
- `⌘⇧O` — IDE-style "open symbol"

## Architecture

A trigger flows through the subsystems like this:

```
EventTap (global CGEventTap; @ / # / ⌘⇧O)
  └─> AppDelegate (owns EventTap, SymbolIndex, OverlayWindowController)
        └─> OverlayWindow + SymbolPickerView / SymbolPickerViewModel  (the picker UI)
              └─> SymbolIndex.search → SymbolMatcher  (strict-substring ranking)
                    ▲
                    │ index built by:
              RepoScanner (git ls-files) ──> Indexer ──> SymbolParser/TreeSitterParser
                                                       (per-language symbol extraction)
        └─> TextInjector (inject keystrokes into frontmost app, or clipboard fallback)
```

Source lives under `SymbolScan/SymbolScan/`:
- `App/` — `AppDelegate` (lifecycle, permissions, wiring), `OverlayWindow` (window + controller)
- `Input/` — `EventTap` (CGEventTap), `TextInjector` (inject / clipboard)
- `Index/` — `Symbol`/`Language`/`SymbolKind`, `RepoScanner`, `TreeSitterParser` (+ the
  `SymbolParser` facade), `Indexer` (off-main index build), `SymbolIndex` (+ `SymbolMatcher`,
  `IndexCache`)
- `UI/` — `SymbolPickerView`, `SymbolPickerViewModel`
- `Capture/` — `OCREngine`, `ScreenCapture`. **Currently unused / dead code** (no callers); see `TASKS.md` T9 before relying on it.

Symbols are extracted by `TreeSitterParser` from real Tree-sitter grammars: **Swift, Python,
TypeScript (`.ts`), TSX (`.tsx`), JavaScript (`.js`/`.jsx`), Rust, Go**.

`Language` is the **grammar key**, not a display value — `.typescript` and `.tsx` are the same
language but different grammars (the TS grammar can't parse JSX), while `.js` and `.jsx` share
one, because the JavaScript grammar handles JSX natively. There is **no fallback extractor**:
a grammar that fails to build logs once and indexes nothing for that language.

## Build / run / test

See `DEVELOPMENT.md` for the full setup (stable code-signing to keep the Accessibility
grant, permissions, troubleshooting). In short:
- Build/run from Xcode (`Cmd+R`); tests via `Cmd+U` or
  `cd SymbolScan && xcodebuild test -scheme SymbolScan -destination 'platform=macOS'`.
- CI runs the same `xcodebuild test` on every push/PR (`.github/workflows/tests.yml`,
  pinned to the `macos-26` runner).

Test seams worth knowing:
- `AppDelegate` early-returns under the test host (the `XCTestConfigurationFilePath`
  guard) so unit tests don't trigger the event tap, Accessibility prompt, or indexing.
- `SymbolIndex.loadForTesting(_:)` (DEBUG-only) seeds a known symbol set without git/IO.

## Conventions

- **Matching is strict substring** ("contains"), ranked in `SymbolMatcher`. The
  scattered-subsequence fuzzy fallback was intentionally removed (it surfaced surprising
  results like "selectedText" for the query "set").
- Pure, testable logic (e.g. `SymbolMatcher`) is kept off `@MainActor` and free of IO so it
  can be unit-tested in isolation — preserve that separation when extending it.

## Where work is tracked

Standing backlog (bugs, features, polish) lives in **`TASKS.md`** at the repo root. When you
finish something, check it off and move it to the Done section with the commit/PR ref. There
are known correctness bugs queued there (T1 hardcoded repo path, T2 path truncation) — read
before touching the indexing path.
