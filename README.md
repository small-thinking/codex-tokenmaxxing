# Codex Tokenmaxxing

A small native macOS menu bar app for your Codex **weekly quota**.

- Outer ring: quota remaining, from 100% to 0%.
- Inner ring: time remaining until the weekly reset, from full to empty.
- Percentage: the latest weekly quota reading.
- Click for the reset countdown, exact local reset time, refresh, and quit.

This first iteration deliberately focuses on the menu bar. History charts, pacing analytics, reset-credit cards, and launch at login are planned separately.

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

The SwiftPM wrapper keeps caches inside `.build`. If an upgraded Command Line Tools installation contains mismatched old private/new public `PackageDescription` interfaces, it creates a project-local mirror using the matching public interface and library. It never edits the installed Apple toolchain.

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

Expired or missing reset metadata does not create a fabricated new quota window. Unknown data shows a question-mark ring and an em dash. Failed refreshes keep the last successful reading, dim the rings, and add a dot after the percentage; the popover explains the failure. Readings older than ten minutes are also marked stale.

### Refresh and resource use

- Background quota refresh every five minutes; no overlapping reads.
- Opening an old reading refreshes it; while open, refresh at most once a minute.
- Local time-based drawing every thirty seconds, without network requests.
- Refresh on wake and network restoration.
- Bounded exponential backoff after errors and reconnection after process failure.
- Twenty-second timeout for each RPC.

The local app-server is an additional process, so the app is not zero-cost. Its memory, CPU, and network use depend on the installed Codex version and configuration. Future versions will measure longer-running idle behavior before changing the polling policy. No assumption is made that a separate app-server receives every usage notification from other Codex processes.

### Privacy and storage

Quota is fetched from OpenAI through the user's installed Codex. This app does not read `auth.json`, hold an access token, start a model turn, redeem reset credits, or send usage to a project-owned server. It disables analytics for its own child process and does not save raw RPC responses or account details.

Version 0.1 keeps the latest reading **in memory only**. Restarting starts with unknown data until a new successful read. This avoids stale persisted readings from a previous account. Local history storage will be introduced with the history chart.

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
Sources/QuotaMenuApp/       AppKit status item and SwiftUI popover
Tests/                     Quota contracts and fake-server transport tests
Resources/Info.plist        Menu-bar-only app metadata
scripts/                   Build, test wrapper, local install
```

The two-ring information design is inspired by [CodexMeter](https://github.com/raycalrui/CodexMeter). This repository implements a smaller app with its own drawing and connection code.
