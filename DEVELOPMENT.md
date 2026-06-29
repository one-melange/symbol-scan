# SymbolScan — Developer Workflow

## One-time setup

### 1. Stable code signing (keeps the Accessibility grant)

SymbolScan needs Accessibility access to run its global `CGEventTap`. macOS ties that
grant to the app's code signature, so an **ad-hoc** signed build loses the grant on every
rebuild (the signature's hash changes) and re-prompts each run. Signing with a stable
**Apple Development** identity fixes this — the grant then persists across rebuilds.

A free Apple ID is enough (no paid Developer Program required):

1. Xcode → **Settings → Accounts → "+" → Apple ID** → sign in. This registers a free
   **Personal Team**.
2. Select the **SymbolScan** project → **SymbolScan** target → **Signing & Capabilities** →
   check **Automatically manage signing** → pick your **(Personal Team)** in the **Team**
   dropdown. Xcode writes `DEVELOPMENT_TEAM` into the project for you.

Verify a build is properly signed (not ad-hoc):

```bash
codesign -dv --verbose=2 SymbolScan/build/Products/Debug/SymbolScan.app
# expect: Authority=Apple Development: …  and a real TeamIdentifier (not "not set")
```

### 2. Accessibility permission

With stable signing in place you grant Accessibility **once** and it survives rebuilds:

1. Build and run from Xcode (`Cmd+R`).
2. System Settings → Privacy & Security → **Accessibility** → enable **SymbolScan**.
3. Done — the grant persists across subsequent rebuilds.

> If you ran an ad-hoc build before signing was set up, remove the stale **SymbolScan**
> entry from the Accessibility list (select it, click "−") and re-grant on the signed build.

---

## Daily workflow

Work on a feature branch with Claude Code, then build and run from Xcode:

1. Make changes (in Xcode or via Claude Code on the feature branch).
2. `Cmd+B` to build, `Cmd+R` to run.

---

## Testing

Unit and headless-interaction tests live in the **SymbolScanTests** target (Swift Testing).
They cover the pure logic — symbol matching/ranking, the per-language `RegexParser`,
`RepoScanner` path helpers, language detection — and drive the real `SymbolPickerViewModel`
+ `SymbolIndex` through the picker flow (type → filter → arrow → select) without any UI,
git, or system permissions.

Run them:

- **Xcode:** select the **SymbolScan** scheme → `Cmd+U`.
- **CLI:**
  ```bash
  cd SymbolScan
  xcodebuild test -scheme SymbolScan -destination 'platform=macOS'
  ```

Notes:
- The app's heavy launch work (event tap, Accessibility prompt, repo indexing) is skipped
  under the test host — see the `XCTestConfigurationFilePath` guard in `AppDelegate`.
- `SymbolScanTests` is an **app-hosted** unit test bundle (`TEST_HOST` = the app), so
  `@testable import SymbolScan` can reach internal types. It builds for **macOS only**.
- The matching/ranking logic is isolated in `SymbolMatcher` (in `SymbolIndex.swift`) so it
  can be tested without `@MainActor`/IO. Seed a known symbol set in view-model tests via
  `SymbolIndex.loadForTesting(_:)` (DEBUG-only).
- CI runs the same `xcodebuild test` on every push/PR — see `.github/workflows/tests.yml`.

When adding a test file, drop it in `SymbolScanTests/` — the target uses a file-system
synchronized group, so new files are picked up automatically (no project edit needed).

---

## Permissions reference

| Permission | Required for | Where to grant |
| --- | --- | --- |
| Accessibility | `CGEventTap` global keystroke detection | System Settings → Privacy & Security → Accessibility |
| Screen Recording | `ScreenCaptureKit` screen capture | System Settings → Privacy & Security → Screen Recording (prompted automatically on first use) |

---

## Troubleshooting

**CGEventTap not working / keystrokes not detected**
- Confirm the build isn't ad-hoc signed (see the `codesign` check above) — an ad-hoc build
  loses Accessibility trust on each rebuild.
- Toggle Accessibility off and back on in System Settings.
- Check console output — if you see `⚠️ Failed to create CGEventTap` the permission isn't active.

**0 symbols indexed**
- App Sandbox must be disabled — check Signing & Capabilities in Xcode, App Sandbox should not be present.
- Verify the repo has tracked Swift/Python/TS/Rust/Go files: `git ls-files | grep -E "\.(swift|py|ts|rs|go)$"`
