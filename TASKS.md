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

Recommended execution order: **T4 → T7.**

- [ ] (T4) Incremental reindex on save — the dead `SymbolIndex.reindexFile` was removed in T19; this is now purely "add a file watcher that re-parses just the saved file and refreshes the `IndexCache`" (build from scratch, likely as a per-repo background job like T19) · `SymbolScan/SymbolScan/Index/SymbolIndex.swift`
- [ ] (T7) RepoScanner robustness — add a file-size cap, expand excluded dirs (`target/`, `vendor/`, `__pycache__/`, `.next/`, …), handle symlinks · `SymbolScan/SymbolScan/Index/RepoScanner.swift`
- [ ] (T8) Language coverage — **superseded by T16** (now landed); the Tree-sitter parser distinguishes method-vs-function via ancestry and adds Go struct/interface/alias, Rust impl methods, etc. Remaining gap: JS/JSX (`.js`/`.jsx` not in `Language.detect`). Reopen only for that · `SymbolScan/SymbolScan/Index/TreeSitterParser.swift`

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

- [x] (T19) Background / non-blocking indexing + multi-repo + completion notification — root cause of the large-repo freeze was a `Process`/`Pipe` deadlock in `RepoScanner.gitLsFilesRaw`: it called `waitUntilExit()` *before* draining stdout, so a repo whose `git ls-files` output exceeded the ~64KB pipe buffer (e.g. `a-large-monorepo`, tens of thousands of files, >1 MB) blocked git on a full pipe while the app blocked waiting for git — a hang that never completed. Fixed by reading stdout to EOF before waiting + discarding stderr to `nullDevice`. Indexing also moved off the `@MainActor` into a nonisolated `Indexer.buildIndex` (`Task.detached`); `SymbolIndex` now holds an active-repo view plus a per-repo background job registry (`jobs: [URL: Task]`) so repos index concurrently and switching never cancels another repo's job (publishes guarded by `indexedRepoRoot`). Real-scan completion posts a `UNUserNotificationCenter` banner (`IndexNotifier`) + live menu-bar tooltip; cache hits stay silent. `activateRepo`/`reindex` are synchronous non-blocking launchers; dead-repo cleanup via `SymbolIndex.onRepoInvalid`; removed the dead `reindexFile`/`scanner` (see T4). Regression test `RepoScannerTests.enumerateAllFilesDoesNotDeadlockOnLargeGitOutput` (real repo, >64KB output — hangs the run if the deadlock returns). **Verified live** on `a-large-monorepo` (tens of thousands of symbols, UI responsive). Not yet tested: the job-manager concurrency + `Indexer.buildIndex` composition (needs a testability seam — see T14) · `SymbolScan/SymbolScan/Index/Indexer.swift`, `Index/SymbolIndex.swift`, `Index/RepoScanner.swift`, `App/IndexNotifier.swift`, `App/AppDelegate.swift` · branch `tree_sitter`
- [x] (T16) Tree-sitter parsing — replaced the regex extractor with real Tree-sitter grammars (Swift, Python, TypeScript, Rust, Go) behind a new `TreeSitterParser` + `SymbolParser` facade that keeps the `parse(source:language:path:)` boundary and falls back to `RegexParser` on any grammar/parse/query failure. Method-vs-function is now decided by node ancestry (not indentation); Go struct/interface/alias and Swift class/struct/enum/actor/protocol are disambiguated from the parse tree. Five grammar SwiftPM packages added to `project.pbxproj` (Swift pinned by revision to the `-with-generated-files` tag; others by exact version) and linked **statically** (no dylib signing); removed the machine-specific `HEADER_SEARCH_PATHS`. `IndexCache.version` bumped 2→3. `RegexParser` retained as fallback + its tests · `SymbolScan/SymbolScan/Index/TreeSitterParser.swift` + build · branch `tree_sitter`
- [x] (T17) Path injection — picking a **code symbol** now injects the file reference plus the name as `@<relativePath>:<line> <name>` (e.g. `@Index/SymbolIndex.swift:105 search`) instead of the bare name, consumed by `SymbolPickerViewModel.selectedInjectionText()` and `OverlayWindowController.confirmAndHide` (used for both inject and Tab-copy). **Follow-up fix:** the `@` was double-injected (`@@`) because the `@`/`#` triggers pass their keystroke through to the target app — so `Symbol.injectionText` now returns the reference *body* only and the leading marker comes from the trigger (nothing for `@`/`#`, a supplied `@` for `⌘⇧O`) via the pure `InjectionComposer`. Both covered by `LanguageAndSymbolTests` + `InjectionComposerTests` (incl. the exact `@@` regression) · branch `tree_sitter`
- [x] (T18) Directory and file recognition — every git-tracked file (any type) and every directory is now indexed as a searchable/injectable entry (`SymbolKind.file` / `.directory`); a file injects `<filename> <parent dir>` and a directory injects `<dir name> <parent dir>`. `RepoScanner.enumerateAllFiles()` (unfiltered git ls-files / FileManager walk) + `RepoScanner.directories(for:)` feed `SymbolIndex.reindex`; `IndexCache.version` bumped 1→2 to drop stale caches. Also fixed a latent `relativePath` symlink-aliasing bug (`/var`↔`/private/var`) · branch `tree_sitter`

- [x] (T1) Hardcoded repo path — removed; the active repo is persisted in `UserDefaults` (`RepoPreference` in `Index/RepoScanner.swift`) and restored on launch, with stale/deleted paths cleared automatically · branch `t3_t1_impl`
- [x] (T3) Repo selection + reindex UI — menu-bar status item (Choose Repo… / Reindex / recent repos / Quit) plus ⌘O / ⌘R / ⌘Q in the overlay; `NSOpenPanel` directory picker; truthful empty state (old copy referenced a nonexistent icon); occlusion warning when the icon is hidden by a full menu bar/notch; overlay now centered + top-pinned on the focused screen (multi-monitor fix, `OverlayPlacement`) · branch `t3_t1_impl`
- [x] (T5) Index persistence — pulled into T3: per-repo JSON cache (`IndexCache` in `Index/SymbolIndex.swift`) under `~/Library/Application Support/SymbolScan/index/`, loaded on activation so repo switches and relaunches skip the rescan; refresh is manual via Reindex (⌘R) · branch `t3_t1_impl`
- [x] (T2) Path-truncation / dead `relPath` — the initial index stored a bare filename instead of the repo-relative path. Fixed by giving `RegexParser.parse(url:language:relativePath:)` an explicit relative path and threading the already-computed `relPath` in at both call sites; dropped `reindexFile`'s now-redundant re-stamp · `SymbolScan/SymbolScan/Index/SymbolIndex.swift` + `Index/RegexParser.swift` (branch `t2_fix`)
