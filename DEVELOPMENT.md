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
2. Set your team **without editing the tracked project**: copy the template and drop in your
   Team ID.

   ```bash
   cp SymbolScan/Local.xcconfig.example SymbolScan/Local.xcconfig
   # then edit SymbolScan/Local.xcconfig: DEVELOPMENT_TEAM = <YOUR_TEAM_ID>
   ```

   `Local.xcconfig` is git-ignored and feeds `DEVELOPMENT_TEAM` into the build via the
   tracked `SymbolScan/Config.xcconfig`, so your signing identity never lands in a commit.
   Find your Team ID in **Settings → Accounts → your Apple ID → Team ID**.

> Prefer the file over the GUI: setting the team through **Signing & Capabilities** writes
> `DEVELOPMENT_TEAM` back into the tracked `project.pbxproj`, which re-introduces your team
> into version control. If Xcode does that, move the value into `Local.xcconfig` and revert
> the project change. (Automatic signing still works — the team just comes from the xcconfig.)

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

### 3. Vendor the local-LLM runtime (for the ⌘E "explain" feature)

The ⌘E "explain symbol" feature (T28) runs a bundled `llama-server`. It isn't checked into
git (~23 MB of binaries), so fetch it once:

```bash
./scripts/fetch-llama.sh
```

This downloads a **pinned** llama.cpp release (macOS arm64), verifies its checksum, and stages
the runtime into `SymbolScan/Vendor/llama/` (git-ignored). The Xcode **"Bundle llama runtime"**
build phase then copies it into `SymbolScan.app/Contents/Helpers/llama/` and re-signs it.

- The app **builds and runs without this** — ⌘E just reports the runtime isn't bundled until
  you run the script.
- **`./scripts/install.sh` runs this for you** before its Release build, so an installed app
  always has the runtime. You only need to run `fetch-llama.sh` by hand for **Xcode** (`Cmd+R`)
  builds. It's idempotent (a no-op once staged; `--force` refetches).
- The **model** (~2 GB GGUF) is **not** vendored: the app downloads it on first launch into
  `~/Library/Application Support/SymbolScan/models/` and shows progress in the menu bar and the
  ⌘E pane. Nothing to do here.

---

## Daily workflow

Work on a feature branch with Claude Code, then build and run from Xcode:

1. Make changes (in Xcode or via Claude Code on the feature branch).
2. `Cmd+B` to build, `Cmd+R` to run.

---

## Install / run outside Xcode

SymbolScan is a menu-bar (`.accessory`) app — for real use you want it running without Xcode
attached. Install a Release build into `/Applications`:

```bash
./scripts/install.sh
```

The script builds Release, quits any running copy, replaces `/Applications/SymbolScan.app`, and
launches it. Signing comes from your normal `Local.xcconfig` (`DEVELOPMENT_TEAM`) — the same stable
identity that keeps the Accessibility grant alive, so reinstalls don't re-prompt.

Once it's running, open the menu-bar menu and tick **Open at Login** to have it start automatically
on future logins. This registers the app via `SMAppService.mainApp`; it's only meaningful for the
installed `/Applications` copy — a login item pointing at a DerivedData/Xcode build path won't
relaunch. The app ships as an agent (`LSUIElement`), so it starts straight into the menu bar with
no dock icon or launch flash.

### Changing the app icon

The icon is a single **1024×1024** PNG (transparent corners — you draw the rounded squircle
yourself; macOS does not mask it) at:

```
SymbolScan/SymbolScan/Assets.xcassets/AppIcon.appiconset/icon.png
```

The set uses the single-size format (one image assigned to the `mac` `512pt@2x` slot), so to
replace the icon just drop in a new 1024×1024 `icon.png` — no `Contents.json` edit. macOS scales
that master down for smaller displays (Finder lists, etc.); if a hand-tuned small size is ever
needed, add the per-size PNGs (16/32/64/128/256/512) back to the set.

---

## Testing

Unit and headless-interaction tests live in the **SymbolScanTests** target (Swift Testing).
They cover the pure logic — symbol matching/ranking, the per-language Tree-sitter queries in
`TreeSitterParser`, `RepoScanner` path helpers, language detection — and drive the real `SymbolPickerViewModel`
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
