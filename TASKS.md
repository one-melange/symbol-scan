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

### Tier 1 — Correctness (verified bugs)

- [ ] (T1) Hardcoded repo path — app only works on one machine; indexes a fixed path every launch · `SymbolScan/SymbolScan/App/AppDelegate.swift:41` (ties to T3)
- [ ] (T2) Path-truncation / dead `relPath` — every symbol stores a bare filename, not its repo-relative path · `SymbolScan/SymbolScan/Index/SymbolIndex.swift:35` + `Index/RegexParser.swift:11`. Fix: thread `relPath` into the `parse(source:language:path:)` overload (already used correctly by `reindexFile`).

### Tier 2 — Core features / robustness

- [ ] (T3) Repo selection + reindex UI — no way to pick a repo or reindex without restarting; empty-state text references a nonexistent menu-bar icon · `SymbolScan/SymbolScan/UI/SymbolPickerView.swift` (consider multi-repo)
- [ ] (T4) Incremental reindex on save — `SymbolIndex.reindexFile` exists but has no callers; wire up a file watcher or remove the dead method · `SymbolScan/SymbolScan/Index/SymbolIndex.swift:56`
- [ ] (T5) Index persistence — index is in-memory only, full reindex every launch; persist + restore
- [ ] (T6) Configurable hotkey — trigger keys (⌘⇧O, `@`, `#`) are hardcoded · `SymbolScan/SymbolScan/Input/EventTap.swift`
- [ ] (T7) RepoScanner robustness — add a file-size cap, expand excluded dirs (`target/`, `vendor/`, `__pycache__/`, `.next/`, …), handle symlinks · `SymbolScan/SymbolScan/Index/RepoScanner.swift`
- [ ] (T8) Language coverage — no `.js`/`.jsx`; Python `@property`/decorated methods missed; re-check the space/tab indentation heuristic for method-vs-function · `SymbolScan/SymbolScan/Index/RegexParser.swift`

## Later

### Tier 3 — Polish / hygiene

- [ ] (T9) Decide on `Capture/` *(verified)* — `OCREngine` + `ScreenCapture` (~140 LOC) have zero callers; wire up OCR-driven triggering or delete both files · `SymbolScan/SymbolScan/Capture/`
- [ ] (T10) Logging — replace `print()` debug logging with `os.Logger`; remove the global per-keystroke log (privacy — logs all typing) · `SymbolScan/SymbolScan/Index/SymbolIndex.swift`, `Index/RepoScanner.swift`, `Input/EventTap.swift`
- [ ] (T11) TextInjector — add injection-failure fallback (clipboard); note the `& 0xFFFF` BMP truncation (low impact for ASCII symbols) · `SymbolScan/SymbolScan/Input/TextInjector.swift:22`
- [ ] (T12) Picker UX *(reported)* — stable row IDs instead of `\.offset`, VoiceOver labels on rows, fix empty-state copy, full-signature tooltip · `SymbolScan/SymbolScan/UI/SymbolPickerView.swift`
- [ ] (T13) Deployment target — confirm `MACOSX_DEPLOYMENT_TARGET = 26.0` is intentional (very narrow audience; CI pinned to `macos-26`) or lower it · `SymbolScan/SymbolScan.xcodeproj/project.pbxproj`
- [ ] (T14) Test gaps — no coverage for `EventTap`, `OverlayWindow`, `AppDelegate`, `Capture/`; add where feasible (rest is well covered)
- [ ] (T15) Cleanups — hoist regex patterns to `static let`; document magic numbers (0.12s focus delay, 0.62 Y-position, 0.05s inject delay, search `limit: 10`)

## Done

_(nothing yet)_
