# codexU

codexU is a macOS desktop widget for tracking OpenAI Codex / ChatGPT Codex and Claude Code quota, token usage, and today's task status. It keeps the information you check most on the desktop, so you can quickly see remaining quota, reset times, and daily work progress.

![codexU desktop widget screenshot](docs/screenshot-0.2.0.png)

## Who It Is For

- Developers who use OpenAI Codex, Codex CLI, or the Codex desktop app every day.
- Developers who use both Codex and Claude Code and want one local view for both runtimes.
- ChatGPT Pro / Team users who want a quick view of Codex 5-hour quota, 7-day quota, token usage, and reset times.
- macOS users who want to check Codex status without repeatedly opening a browser or terminal.

## Features

- Shows remaining and used Codex quota for the 5-hour and 7-day windows, including reset times.
- Adds a menu bar runtime menu with separate Codex and Claude Code cards, 5-hour/7-day remaining quota, today's token usage, and total tokens today.
- Adds a top-level `Codex | Claude Code` switch in the main widget so all panels can switch runtime scope manually.
- Supports Claude Code local transcript usage, 7-day trends, project rankings, top tools/Skills, and a basic task board.
- Summarizes token usage for today, the last 7 days, and lifetime totals with uncached input, cached input, and output splits.
- Estimates the current month's API-equivalent value from OpenAI API token prices and shows progress against Plus, Pro 100, Pro 200, and the full monthly quota value.
- Adds lower dashboard tabs for today's tasks, usage trend, project ranking, and Skill usage.
- Builds a daily task board from local Codex threads and enabled Codex automations, grouped into active, pending, scheduled, and done columns.
- Shows a six-month daily token heatmap, a last-7-day trend summary, and previous-period comparison.
- Shows recent and all-time project rankings with tokens, estimated value, thread counts, and recent activity.
- Shows top tool calls and top Skill usage to explain the structure of local Codex work.
- Stays on the desktop layer by default, with `Command + U` temporary foreground access that returns to the desktop layer on focus loss, plus a top pin button for always-on-top mode.
- Supports Chinese and English UI text. The default language follows the system time zone, and the top `中 | EN` switch can override it.
- Supports system, light, and dark appearance modes. The default follows macOS, and the top appearance switch can override it.
- Reads data locally and does not upload usage, threads, or account data to a third-party service.

## Keyboard Shortcuts

- `Command + U`: temporarily bring the widget from the desktop layer to the foreground; press again while foregrounded to return it to the desktop layer, or let it return automatically on focus loss.
- Menu bar gauge icon: opens the runtime menu. Clicking a Codex or Claude Code card opens the main widget with that runtime selected.
- Top pin button: pin or unpin the widget in the foreground. It is off by default; when enabled, the widget stays in front after focus loss.
- Top appearance switch: switch between system, light, and dark modes. System mode follows macOS.
- Top `中 | EN` switch: switch between Chinese and English. Manual selection is kept for the next launch.
- Refresh button: immediately refresh quota, token usage, trend, and task board.
- Close button: quit the widget.
- Drag anywhere on the widget background to reposition it.

## First Install: Privacy & Security

codexU is distributed outside the Mac App Store. On first launch, macOS may block it until you manually allow it:

1. Open `codexU.app` once. If macOS says it cannot be opened, cancel the dialog.
2. Open **System Settings > Privacy & Security**.
3. In the **Security** section, click **Open Anyway** for `codexU.app`.
4. Confirm with Touch ID or your password, then click **Open**.

You can also right-click `codexU.app` in Finder and choose **Open**, then confirm the same security prompt.

codexU needs access to local Codex data under `~/.codex/`. When Claude Code stats are used, it also reads local transcripts, tasks, and status cache files under `~/.claude/`. If macOS asks for file or folder access, allow it so the widget can read local usage, threads, and automation metadata.

## Install

Download the DMG for your Mac architecture from GitHub Releases:

- Apple Silicon: `codexU-<version>-mac-arm64.dmg`
- Intel: `codexU-<version>-mac-x86_64.dmg`

1. Open the DMG.
2. Drag `codexU.app` into the `Applications` folder.
3. Open codexU from `Applications`.
4. Complete the **First Install: Privacy & Security** steps above if macOS blocks the first launch.

## Requirements

- macOS 14 or later.
- A local Codex installation.
- A signed-in Codex account for quota data.
- Codex must have been used at least once so `~/.codex/state_5.sqlite` exists.
- Claude Code support is optional. Historical tokens come from `~/.claude/projects/**/*.jsonl`; quota requires a local statusLine snapshot cache.
- Xcode Command Line Tools for building from source.

## Build From Source

```sh
make build
```

Run the app:

```sh
make run
```

Install to `/Applications`:

```sh
make install
```

Inspect the data source output:

```sh
make probe
```

## Package A DMG

```sh
make release
```

`make release` builds a DMG for the current build machine architecture. You can also build explicit Mac architectures:

```sh
make release-arm64
make release-intel
make release-all
```

Release artifacts are written to `dist/`, for example:

```text
dist/codexU-0.3.0-mac-arm64.dmg
dist/codexU-0.3.0-mac-arm64.dmg.sha256
dist/codexU-0.3.0-mac-x86_64.dmg
dist/codexU-0.3.0-mac-x86_64.dmg.sha256
```

For Developer ID signing and notarization, see [DISTRIBUTION.md](DISTRIBUTION.md).

## Data Sources

- Account and quota: `codex app-server` JSON-RPC methods `account/read`, `account/rateLimits/read`, and `account/usage/read`.
- Local token totals: `~/.codex/state_5.sqlite`.
- Detailed token splits: `token_count` events in `~/.codex/sessions/**/rollout-*.jsonl` and `~/.codex/archived_sessions/*.jsonl`.
- Today's board: unarchived and archived Codex threads in the local SQLite database.
- Usage trends and project rankings: aggregated from local session `token_count` events, with an approximate thread-updated-time fallback when detailed events are unavailable.
- Tool and Skill usage: tool call and Skill load records parsed from local session events.
- Scheduled tasks: enabled automation metadata under `~/.codex/automations/**/automation.toml`.
- Claude Code historical tokens: assistant `message.usage` fields in `~/.claude/projects/**/*.jsonl`.
- Claude Code tools, Skills, and tasks: transcript `tool_use.name` / explicit Skill attribution, plus `~/.claude/tasks/**/*.json`.
- Claude Code active quota: optional `~/Library/Caches/codexU/claude-code/statusline-snapshot.json`; without it, 5-hour and 7-day quota show `--`.

Current Codex quota APIs expose rolling-window percentages and reset times, not absolute account quota sizes. Claude Code v0.4.0 reads local history and an optional active snapshot; it is not a Claude.ai official billing view. See [RESEARCH.md](RESEARCH.md) for the data model and fallback behavior.

## FAQ

### Is codexU an official OpenAI product?

No. codexU is an unofficial local macOS utility for reading local Codex app-server responses and local `~/.codex/` data.

### Does codexU upload my Codex threads or usage data?

No. codexU reads Codex quota, local SQLite usage, and automation metadata locally. It does not upload that data to a third-party service.

### Why does codexU show remaining percentage instead of absolute quota?

The current local Codex API exposes rolling-window usage percentages and reset times, not absolute quota sizes. codexU therefore shows remaining percentages for the 5-hour and 7-day windows.

### Does codexU support Intel Macs?

Yes. Intel Macs should use `codexU-<version>-mac-x86_64.dmg`. From source, package it with `make release-intel`, or override `TARGET_TRIPLE="x86_64-apple-macos14.0"` from a compatible toolchain.

## License

MIT. See [LICENSE](LICENSE).

## WeChat Official Account

Scan the QR code to follow my WeChat official account for AI tools, Codex usage notes, and independent product building.

<img src="docs/wechat-official-account-qr.png" alt="WeChat official account QR code" width="220" />
