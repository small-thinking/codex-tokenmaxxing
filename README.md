# Codex Tokenmaxxing

A small native macOS menu bar app for your Codex **weekly quota**.

- Outer ring: quota remaining, from 100% to 0%.
- Outer ring color: **green at 80–100%**, **mint/teal at 50–<80%**, **amber at 20–<50%**, and **red below 20%**. The empty track stays red at 0%.
- Inner ring: time remaining until the weekly reset, from full to empty. Its colors run in reverse: **red above 80% time remaining**, **amber at >50–80%**, **mint/teal at >20–50%**, and **green at 20% or less**. Green means the reset is near, not that quota is abundant.
- Reset opportunities: server-reported available count, expiry dates, and each card’s remaining validity progress.
- Click for labeled ring percentages, the reset countdown, exact local reset time, weekly pace, refresh, and quit.
- Compare the rings’ **filled proportions/angles**, not their physical arc lengths. Quota remaining minus time remaining gives the gap from uniform weekly use in percentage points: +20 pp (60% quota, 40% time) is under pace. The compact label writes this as `Under pace · 20%`; its tooltip explains that it is an absolute percentage-point gap, not a relative percentage change. This does not measure recent activity. Stale readings hide pace.

This app focuses on a compact menu bar overview. The hourly activity chart compares observed quota consumption with a dynamic target pace. Launch at login is planned separately.

## Requirements

- macOS 13 or later; currently validated on Apple Silicon macOS 26.
- Swift 6 or later and the macOS SDK, from Apple's **Command Line Tools** or Xcode.
- A local Codex installation signed in with a ChatGPT account that exposes a weekly quota.

**The full Xcode IDE is not required for this macOS app.** Command Line Tools supply the Swift compiler and macOS SDK. The scripts compile Swift sources, assemble the app bundle, and apply an ad-hoc local signature. No Xcode project, storyboard compiler, paid signing certificate, or App Store deployment is needed for this local build. This is not a claim about iOS builds or every Apple-platform tool.

See [Apple's Command Line Tools documentation](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools).

## Build and install locally

```sh
# Build dist/Codex Tokenmaxxing.app
./scripts/build-app.sh

# Build, install into ~/Applications, and open the app
./scripts/install-local.sh
```

The app lives in the menu bar and does not show a Dock icon. Quit the existing copy before installing an update; the install script preserves the previous bundle in `~/Library/Application Support/Codex Tokenmaxxing/Backups/`.

An installed app runs independently of Terminal. It launches one owned Codex app-server process and closes that process when you quit. It does not terminate the Codex desktop app or other Codex sessions.

For local development:

```sh
./scripts/swiftpm.sh build
./scripts/test.sh

# A real read-only connectivity check; outputs quota fields, not account details.
"./dist/Codex Tokenmaxxing.app/Contents/MacOS/CodexTokenmaxxing" --check
```

Tests use local fake app-server executables and do not query an authenticated account. The fake servers require `/usr/bin/python3`, supplied by Command Line Tools. A small dependency-free check executable reports each failure and exits nonzero, so neither XCTest nor the Swift Testing runtime is required.

The checks also render the actual AppKit rings offscreen and verify color boundaries, inverse time colors, unknown indicators, and dim neutral stale readings under light and dark appearances. To export a synthetic contact sheet with 1× and enlarged icons after running the tests:

```sh
"$(./scripts/swiftpm.sh build --show-bin-path)/QuotaChecks" --render-rings=.build/ring-preview.png
open .build/ring-preview.png
```

For a synthetic preview of the full popover (debug builds only):

```sh
./scripts/swiftpm.sh build --product CodexTokenmaxxing
"$(./scripts/swiftpm.sh build --show-bin-path)/CodexTokenmaxxing" --render-preview=.build/popover.png
# Add --preview-dark for dark appearance or --preview-empty for first-run activity.
# No account is queried and the real history store is not accessed.
```

The menu-bar button's own appearance controls the palette and triggers redraws when it changes. Percentage text uses native AppKit styling. Offscreen checks do not replace checking the installed status item over your actual wallpaper.

The SwiftPM wrapper keeps caches inside `.build`. If an upgraded Command Line Tools installation contains mismatched old private/new public `PackageDescription` interfaces, it creates a project-local mirror using the matching public interface and library. It never edits the installed Apple toolchain.

## Continuous integration

[Swift checks](../../actions/workflows/swift.yml) runs on every pull request, on pushes to `main`, and on manual dispatch. It validates shell scripts and bundle metadata, runs the dependency-free quota/transport checks, and builds and verifies an ad-hoc signed release app on a macOS 15 runner. CI uses fake Codex responses and does not require a Codex login or account secrets. New commits cancel obsolete runs for the same PR.

## How quota is read

The app starts `codex -c analytics.enabled=false app-server --listen stdio://` and uses newline-delimited JSON-RPC:

1. `initialize`, then `initialized`.
2. `account/read` to validate the signed-in account.
3. `account/rateLimits/read` for quota.
4. Another account read to reject a switch during the refresh.

The `codex` bucket in `rateLimitsByLimitId` takes precedence. Legacy `rateLimits` is accepted when the map is absent or empty. Weekly is identified by its **10,080-minute duration**, in either `primary` or `secondary`; it does not assume that a Pro account always has a particular window layout.

```text
quota remaining = clamp(100 - usedPercent, 0, 100)
time remaining  = clamp((resetsAt - now) / (windowDurationMins × 60), 0, 1)
```

Expired or missing reset metadata does not create a fabricated new quota window. Unknown data shows a neutral question-mark ring and an em dash. Failed refreshes keep the last successful reading, switch the rings to dim neutral shades, and add a dot after the percentage; the popover explains the failure. Readings older than ten minutes are also marked stale.

### Reset opportunities

The optional `rateLimitResetCredits` bank comes from the **same** quota response, so displaying it adds no polling requests. The count is the last server-reported `availableCount`; detail rows can be capped or unavailable. Only available Codex reset opportunities are listed, with the earliest expiry first.

```text
validity remaining = clamp((expiresAt - now) / (expiresAt - grantedAt), 0, 1)
```

Unknown or invalid dates show unavailable progress. An opportunity that expires locally is labeled expired and triggers a refresh at the next timer tick; the app does not invent a replacement count. Weekly quota and reset opportunities are cleared together on sign-out/account changes. Missing optional reset data does not discard valid weekly quota.

The validity bar is separate from the inner ring: it tracks the card’s lifetime from grant to expiry. The inner ring tracks the weekly reset window. Cards are displayed read-only; this version has no redemption control.

For a read-only diagnostic that prints only count and expiry dates (no card IDs or account data):

```sh
"./dist/Codex Tokenmaxxing.app/Contents/MacOS/CodexTokenmaxxing" --check-resets
```

### Hourly activity and pace

The last 24 hourly bins show **observed weekly-quota consumption**, not raw token counts. The dashed line is the **current required pace**: `quota remaining / hours until reset`. For example, 60% remaining with 120 hours left gives 0.50% per hour; if the quota is unchanged and only 60 hours remain, it becomes 1.00% per hour. The horizontal line updates every 30 seconds using the in-memory reading, without additional polling or disk writes. Stale, expired or unavailable readings hide the target, and the axis expands to include high targets near reset. This is different from the top-level pace gap, which compares quota remaining with weekly time remaining.

Each successful poll records a quota snapshot. The increase between adjacent readings is split across hour boundaries in proportion to elapsed time, so within-interval timing is an estimate. Only readings within 15 minutes and the same quota window can connect. Resets, decreasing values, clock reversal, account switches and app restarts break the chain. Missing data is never treated as zero usage.

Solid bars have at least 95% observation coverage. Faded bars indicate incomplete coverage or the current, unfinished hour; a dash indicates no observed interval. Hover over a bar for its value, local hour and observation coverage. Partial hours should not be compared directly with the current full-hour target line. On first launch the chart collects new readings; it cannot backfill activity from before installation.

History is bounded to eight days / 10,000 samples in `~/Library/Application Support/Codex Tokenmaxxing/quota-history.json`, written atomically with owner-only file permissions. A SHA-256 digest of the verified account metadata separates accounts; raw account metadata is not stored. A changed account profile can start a new partition. History is disabled if an identifying account field is unavailable. Corrupt files start a new history with a visible warning, and save failures leave current quota functional and recent activity in memory.

### Refresh and resource use

- Background quota refresh every five minutes; no overlapping reads.
- Opening an old reading refreshes it; while open, refresh at most once a minute.
- Local time-based drawing every thirty seconds, without network requests.
- Refresh on wake and network restoration.
- Bounded exponential backoff after errors and reconnection after process failure.
- Twenty-second timeout for each RPC.

The local app-server is an additional process, so the app is not zero-cost. Its memory, CPU, and network use depend on the installed Codex version and configuration. Future versions will measure longer-running idle behavior before changing the polling policy. No assumption is made that a separate app-server receives every usage notification from other Codex processes.

### Privacy and storage

Quota is fetched from OpenAI through the user's installed Codex. This app does not read `auth.json`, hold an access token, start a model turn, redeem reset credits, or send usage to a project-owned server. It disables analytics for its own child process and does not save raw RPC responses or raw account details.

The current quota and reset-credit reading stays **in memory only**. Restarting starts with unknown current data until a successful account-checked read. The hourly history stores quota percentages, timestamps, reset-window metadata and an opaque account digest locally; history from another account is never shown as the current account’s activity.

### Codex executable discovery

The app checks the Codex/ChatGPT application bundles and common CLI locations (`~/.local/bin`, Homebrew, `/usr/local/bin`, and `~/.npm-global/bin`). Finder's environment need not match your terminal's PATH. A custom path can be set with:

```sh
defaults write com.small-thinking.codex-tokenmaxxing codexExecutablePath -string /absolute/path/to/codex
```

Quit and reopen the app after changing the path. Use `defaults delete com.small-thinking.codex-tokenmaxxing codexExecutablePath` to remove the override.

The app-server protocol may change with Codex updates; unsupported quota shapes are reported instead of guessed. [Official protocol documentation](https://learn.chatgpt.com/docs/app-server#auth-endpoints).

## Project layout

```text
Sources/QuotaCore/          Quota parsing and time calculations
Sources/CodexConnection/    Owned process, RPC transport, account checks
Sources/QuotaMenuUI/        Appearance-aware quota and time ring drawing
Sources/QuotaMenuApp/       AppKit status item and SwiftUI popover
Tests/                     Quota contracts and fake-server transport tests
Resources/Info.plist        Menu-bar-only app metadata
scripts/                   Build, test wrapper, local install
```

The two-ring information design is inspired by [CodexMeter](https://github.com/raycalrui/CodexMeter). This repository implements a smaller app with its own drawing and connection code.
