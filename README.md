# SymbolScan

A transparent macOS overlay that helps you drop code symbols into prompts for AI coding
tools like Claude Code and Codex — without leaving your keyboard or hunting for the exact
name and path.

[![Tests](https://github.com/one-melange/symbol-scan/actions/workflows/tests.yml/badge.svg)](https://github.com/one-melange/symbol-scan/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)

## What it is

When you're prompting an AI coding assistant, you constantly need to name things —
`SymbolMatcher`, `Index/RepoScanner.swift:42`, a directory path. Typing them from memory is
slow and error-prone.

SymbolScan runs invisibly in the menu bar. A global hotkey pops a transparent picker over
whatever app you're in, you type to filter symbols indexed from your current git repo, and
the one you choose is injected straight into the focused app (or copied to the clipboard).
Code symbols are injected as a file-anchored reference like `@Index/SymbolIndex.swift:105 search`,
so the assistant knows exactly where the symbol lives.

## Triggers

Type one of these anywhere; the picker appears and the trigger character flows through to
your target app:

| Trigger | Intended for | Behavior |
| --- | --- | --- |
| `@` | Claude Code | Pick a symbol, injected as `@<path>:<line> <name>` |
| `#` | Codex | Same, prefixed with `#` |
| `⌘⇧O` | IDE-style "open symbol" | Pick a symbol and inject it into the focused editor |

## Features

- **Real parsing, not regex** — symbols are extracted with actual [Tree-sitter](https://tree-sitter.github.io/tree-sitter/)
  grammars, so method-vs-function is decided by the parse tree rather than indentation guesses.
- **Multi-language** — Swift, Python, TypeScript (`.ts`), TSX (`.tsx`), JavaScript (`.js`/`.jsx`),
  Rust, and Go.
- **Files and directories too** — every tracked file and directory is searchable/injectable
  as a path, alongside in-file symbols.
- **Predictable substring matching** — filtering is strict "contains", ranked so exact and
  prefix hits surface first (no surprising scattered-subsequence matches).
- **Fast and out of the way** — a menu-bar-only (`.accessory`) app with no dock icon; the
  index is built off the main thread and cached per repo, so repo switches and relaunches
  skip the rescan.
- **Inject or copy** — types into the frontmost app when possible, falls back to the clipboard.

## Requirements

- **macOS 14** (Sonoma) or later
- **Xcode 26.5** or later (to build)
- An Apple ID for code signing — a free Personal Team is enough; no paid Developer Program
  required. Stable signing is what lets macOS keep the Accessibility grant across rebuilds
  (see [DEVELOPMENT.md](DEVELOPMENT.md)).

## Getting started

```bash
git clone https://github.com/one-melange/symbol-scan.git
cd symbol-scan
```

1. Open `SymbolScan/SymbolScan.xcodeproj` in Xcode.
2. Set your signing team without touching the tracked project:
   ```bash
   cp SymbolScan/Local.xcconfig.example SymbolScan/Local.xcconfig
   # edit Local.xcconfig: DEVELOPMENT_TEAM = <YOUR_TEAM_ID>
   ```
   `Local.xcconfig` is git-ignored, so your team ID never lands in a commit. Full details,
   including how to find your Team ID, are in [DEVELOPMENT.md](DEVELOPMENT.md).
3. Build and run (`⌘R`).
4. Grant **Accessibility** when prompted (System Settings → Privacy & Security → Accessibility
   → enable **SymbolScan**). This is required for the global hotkey.
5. From the menu-bar item, choose a git repo to index (**Choose Repo…**), then press `@`, `#`,
   or `⌘⇧O` in any app to bring up the picker.

## Install it (run outside Xcode)

SymbolScan is a menu-bar app, so day-to-day you want it running without Xcode open. Once your
signing is set up (step 2 above), install a Release build into `/Applications`:

```bash
./scripts/install.sh
```

This builds Release, copies `SymbolScan.app` to `/Applications`, and launches it — after which
you can start it any time from Spotlight or Finder. To have it start automatically, open the
menu-bar menu and tick **Open at Login** (registered via `SMAppService`; meaningful only for the
installed `/Applications` copy, not a build launched from Xcode).

## How it works

```
EventTap (global CGEventTap; @ / # / ⌘⇧O)
  └─> AppDelegate (owns the event tap, index, and overlay)
        └─> Overlay window + SymbolPickerView          (the picker UI)
              └─> SymbolIndex.search → SymbolMatcher     (substring ranking)
                    ▲
                    │ index built by:
              RepoScanner (git ls-files) → Indexer → TreeSitterParser
                                                    (per-language symbol extraction)
        └─> TextInjector (types into the frontmost app, or copies to the clipboard)
```

The pure, IO-free logic (matching/ranking, per-language queries) is deliberately kept off
the main actor so it can be unit-tested in isolation.

## Testing

```bash
cd SymbolScan
xcodebuild test -scheme SymbolScan -destination 'platform=macOS'
```

Tests live in the **SymbolScanTests** target (Swift Testing) and cover symbol
matching/ranking, the per-language Tree-sitter queries, `RepoScanner` path helpers, language
detection, and the picker flow — no UI, git, or system permissions required. CI runs the
same suite on every push and PR, with a code-coverage gate. See [DEVELOPMENT.md](DEVELOPMENT.md#testing)
for details.

## Contributing

Issues and PRs are welcome. The standing backlog lives in [TASKS.md](TASKS.md), and
architecture notes for contributors are in [CLAUDE.md](CLAUDE.md) and
[DEVELOPMENT.md](DEVELOPMENT.md). Please run the test suite before opening a PR.

## License

[MIT](LICENSE) © 2026 Pritam M.
