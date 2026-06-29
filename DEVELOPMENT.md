# SymbolScan — Developer Workflow

## One-time setup

### 1. Shell aliases

Add these to your `~/.zshrc`:

```bash
# Launch SymbolScan (kills any running instance first)
alias ss="pkill SymbolScan 2>/dev/null; open /Users/pm/Code/symbol-scan/SymbolScan/build/Products/Debug/SymbolScan.app"

# Build SymbolScan from any worktree or subdirectory
alias ssbuild='xcodebuild -project $(git rev-parse --show-toplevel)/SymbolScan/SymbolScan.xcodeproj -scheme SymbolScan -configuration Debug -derivedDataPath $(git rev-parse --show-toplevel)/SymbolScan/build build 2>&1 | grep -E "(error:|warning:|Build succeeded|Build FAILED)"'
```

Then reload:

```bash
source ~/.zshrc
```

### 2. Accessibility permission

SymbolScan uses `CGEventTap` to detect `@` and `#` keystrokes globally. This requires Accessibility access — but only needs to be granted once as long as you always launch via `ss`.

**Never use Xcode's Run button (`Cmd+R`)** — it launches the app as a child of Xcode's process, which bypasses accessibility trust and requires re-granting every time.

To grant:
1. Run `ss` once from terminal
2. System Settings → Privacy & Security → Accessibility → enable SymbolScan
3. Done permanently

### 3. Xcode build location

Build output is set to relative workspace (`SymbolScan/build/`) rather than Xcode's default DerivedData. This keeps the binary path stable across clean builds so accessibility trust is never invalidated.

If you need to reconfigure: Xcode → Settings → Locations → Build Location → Custom → Relative to Workspace, Products: `build/Products`, Intermediates: `build/Intermediates.noindex`.

---

## Daily workflow

### Using Xcode

1. Make changes in Xcode
2. `Cmd+B` to build
3. `ss` in terminal to relaunch

### Using Claude Code / worktrees

```bash
wt claude/your-feature-branch   # switch to worktree
# ... make changes ...
ssbuild                          # build from current worktree
ss                               # relaunch app
```

`ssbuild` uses `git rev-parse --show-toplevel` to find the project root, so it works correctly from any worktree or subdirectory without modification.

---

## Permissions reference

| Permission | Required for | Where to grant |
| --- | --- | --- |
| Accessibility | `CGEventTap` global keystroke detection | System Settings → Privacy & Security → Accessibility |
| Screen Recording | `ScreenCaptureKit` screen capture | System Settings → Privacy & Security → Screen Recording (prompted automatically on first use) |

---

## Troubleshooting

**CGEventTap not working / keystrokes not detected**
- Make sure you launched via `ss`, not Xcode's Run button
- Toggle Accessibility off and back on in System Settings
- Check console output — if you see `⚠️ Failed to create CGEventTap` the permission isn't active

**0 symbols indexed**
- App Sandbox must be disabled — check Signing & Capabilities in Xcode, App Sandbox should not be present
- Verify the repo has tracked Swift/Python/TS/Rust/Go files: `git ls-files | grep -E "\.(swift|py|ts|rs|go)$"`

**`ss` does nothing**
- Test directly: `open /Users/pm/Code/symbol-scan/SymbolScan/build/Products/Debug/SymbolScan.app`
- If that works, reload aliases: `source ~/.zshrc`

**`ssbuild` can't find the project**
- Make sure you're inside the git repo: `git rev-parse --show-toplevel` should return the repo root
