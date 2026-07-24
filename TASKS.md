# SymbolScan — Tasks

Standing backlog for SymbolScan. This is the single source of truth for what's planned,
in progress, and done.

## Convention

- Sections by horizon: **Now** (actively being worked), **Next** (queued), **Later**
  (someday/maybe), **Done** (shipped).
- One line per item: `- [ ] (Txx) Short title — one-line why · file:line`
- When an item ships, check it off and move it to **Done** with the commit/PR ref.
- IDs (`Txx`) are stable — don't renumber. New items get the next free number.
- `(verified)` = confirmed against source. `(reported)` = surfaced by audit, line refs
  not yet verified.

---

## Now

_(nothing in progress)_

## Next

### Tier 2 — Core features / robustness

Recommended execution order: **T4 → T7 → T16.**

- [ ] (T4) Incremental reindex on save — `SymbolIndex.reindexFile` exists but has no callers; wire up a file watcher or remove the dead method · `SymbolScan/SymbolScan/Index/SymbolIndex.swift` (note: should also refresh the `IndexCache` on-disk cache)
- [ ] (T7) RepoScanner robustness — add a file-size cap, expand excluded dirs (`target/`, `vendor/`, `__pycache__/`, `.next/`, …), handle symlinks · `SymbolScan/SymbolScan/Index/RepoScanner.swift`
- [ ] (T16) Tree-sitter parsing — replace the regex extractor with Tree-sitter grammars for accurate cross-language symbols (no brittle indentation heuristics, easy new-language support). Keep the `parse(source:language:path:)` boundary + `Symbol`/`SymbolKind` stable so it's an internal swap; consider a per-language rollout with regex fallback. Pulls in native grammar dylibs (SwiftPM/Xcode + code-signing + CI changes). **Largely subsumes T8.** · `SymbolScan/SymbolScan/Index/RegexParser.swift` (→ new parser layer) + build/CI
- [ ] (T8) Language coverage — **superseded by T16** (JS/JSX, Python `@property`/decorated methods, method-vs-function detection all fall out of a real parse tree); keep only as a regex fallback if T16 slips · `SymbolScan/SymbolScan/Index/RegexParser.swift`

## Later

### Tier 3 — Polish / hygiene

- [ ] (T6) Configurable hotkey — trigger keys (⌘⇧O, `@`, `#`) are hardcoded; *lowered from Tier 2 — hardcoded triggers work fine today* · `SymbolScan/SymbolScan/Input/EventTap.swift`
- [ ] (T9) Decide on `Capture/` *(verified)* — `OCREngine` + `ScreenCapture` (~140 LOC) have zero callers; wire up OCR-driven triggering or delete both files · `SymbolScan/SymbolScan/Capture/`
- [ ] (T10) Logging — replace `print()` debug logging with `os.Logger`; remove the global per-keystroke log (privacy — logs all typing) · `SymbolScan/SymbolScan/Index/SymbolIndex.swift`, `Index/RepoScanner.swift`, `Input/EventTap.swift`
- [ ] (T11) TextInjector — add injection-failure fallback (clipboard); note the `& 0xFFFF` BMP truncation (low impact for ASCII symbols) · `SymbolScan/SymbolScan/Input/TextInjector.swift:22`
- [ ] (T12) Picker UX *(reported)* — stable row IDs instead of `\.offset`, VoiceOver labels on rows, full-signature tooltip (empty-state copy fixed as part of T3) · `SymbolScan/SymbolScan/UI/SymbolPickerView.swift`
- [ ] (T13) Deployment target — confirm `MACOSX_DEPLOYMENT_TARGET = 26.0` is intentional (very narrow audience; CI pinned to `macos-26`) or lower it · `SymbolScan/SymbolScan.xcodeproj/project.pbxproj`
- [ ] (T14) Test gaps — no coverage for `EventTap`, `OverlayWindow`, `AppDelegate`, `Capture/`; add where feasible (rest is well covered)
- [ ] (T15) Cleanups — hoist regex patterns to `static let`; document magic numbers (0.12s focus delay, 0.05s inject delay, search `limit: 10`; the 0.62 Y-position was retired by `OverlayPlacement`)

## Done

- [x] (T17) Path injection — picking a **code symbol** now injects the file reference plus the name as `@<relativePath>:<line> <name>` (e.g. `@Index/SymbolIndex.swift:105 search`) instead of the bare name; composition lives in the pure, tested `Symbol.injectionText`, consumed by `SymbolPickerViewModel.selectedInjectionText()` and `OverlayWindowController.confirmAndHide` (used for both inject and Tab-copy) · branch `tree_sitter`
- [x] (T18) Directory and file recognition — every git-tracked file (any type) and every directory is now indexed as a searchable/injectable entry (`SymbolKind.file` / `.directory`); a file injects `<filename> <parent dir>` and a directory injects `<dir name> <parent dir>`. `RepoScanner.enumerateAllFiles()` (unfiltered git ls-files / FileManager walk) + `RepoScanner.directories(for:)` feed `SymbolIndex.reindex`; `IndexCache.version` bumped 1→2 to drop stale caches. Also fixed a latent `relativePath` symlink-aliasing bug (`/var`↔`/private/var`) · branch `tree_sitter`

- [x] (T1) Hardcoded repo path — removed; the active repo is persisted in `UserDefaults` (`RepoPreference` in `Index/RepoScanner.swift`) and restored on launch, with stale/deleted paths cleared automatically · branch `t3_t1_impl`
- [x] (T3) Repo selection + reindex UI — menu-bar status item (Choose Repo… / Reindex / recent repos / Quit) plus ⌘O / ⌘R / ⌘Q in the overlay; `NSOpenPanel` directory picker; truthful empty state (old copy referenced a nonexistent icon); occlusion warning when the icon is hidden by a full menu bar/notch; overlay now centered + top-pinned on the focused screen (multi-monitor fix, `OverlayPlacement`) · branch `t3_t1_impl`
- [x] (T5) Index persistence — pulled into T3: per-repo JSON cache (`IndexCache` in `Index/SymbolIndex.swift`) under `~/Library/Application Support/SymbolScan/index/`, loaded on activation so repo switches and relaunches skip the rescan; refresh is manual via Reindex (⌘R) · branch `t3_t1_impl`
- [x] (T2) Path-truncation / dead `relPath` — the initial index stored a bare filename instead of the repo-relative path. Fixed by giving `RegexParser.parse(url:language:relativePath:)` an explicit relative path and threading the already-computed `relPath` in at both call sites; dropped `reindexFile`'s now-redundant re-stamp · `SymbolScan/SymbolScan/Index/SymbolIndex.swift` + `Index/RegexParser.swift` (branch `t2_fix`)
