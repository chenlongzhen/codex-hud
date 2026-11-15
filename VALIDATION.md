# Validation record

## 2026-11-15: Codex + Claude HUD local candidate

This change was exercised **only with synthetic inputs, explicit private temporary directories and preview/check modes**. No real Claude/Codex configuration, credentials or default Claude snapshot was read; no normal HUD, `--diagnose` or `claude` was run. No install, login-item change, commit, push, upload or Release publication was performed. Version remains **1.1.0**. Original-release real-account results below are historical, not tests repeated in this change.

Environment: macOS **26.2 (25C56)**, Apple Silicon arm64, Swift **6.0.3**, existing Command Line Tools; Swift language mode remains v5. No downloaded dependencies or toolchain changes.

### Actual results

| Check | Result |
|---|---|
| `./scripts/check.sh` | **339 behavior assertions passed** (original regressions plus strict quota/file/setup cases) |
| Debug `--check-window` | **28 checks passed**, including three suspended-read generation/disable/clear/preview-save cases using debug-only injected reads; both HUD and settings are rendered at synthetic small heights |
| Release `--check-window` | **25 checks passed**; original 14 window checks retained, plus dual tabs, toggle anchoring, hidden Claude menus/tooltips, synthetic small height, platform isolation and preview save/reconnect isolation |
| Release `verify-claude-bridge.sh` | **28 process checks passed** |
| Release fixture closed loop | **11 checks passed**, including observed/16-minute stale/passed/empty-after-reset/absent/waiting/only-5h/corrupt/invalid args, exact width, native check and demo render verification |
| Five synthetic documentation images | Recreated and visually inspected; overview/tokens/tasks are exactly **340pt / 680 pixels at 2×**, dual tab **46×166pt / 92×332 pixels** |
| Local package | ZIP extraction, app signature/plist, included MIT LICENSE and guide, SHA-256 and extracted bridge synthetic smoke test passed |
| Binary audit | Actual Mach-O minimum **13.0**, plist minimum **13.0**, architecture exactly **arm64**, dynamic dependencies **system-only** |
| Unsafe package destinations | Nonempty directory, regular file and installation-directory symlink all rejected with exit **2** before build/write |
| Gatekeeper assessment | `spctl -a -vv`: **rejected**, exit **3**, expected for this ad-hoc/unnotarized candidate; not a notarization or first-launch success |
| Scope/safety | `git diff --check` passed; protected Codex data-layer/build/package-manifest files unchanged; installed app directory timestamps unchanged |

Final local ZIP SHA-256: `40d4ac951599a375fa04a5bb3127afa76f545387ab59c5b565591db395d7b72b`. This identifies the unpublished candidate, not an existing GitHub asset.

Core coverage includes bounded strict integer timestamps and Int64 extremes; rollback by 120s and >300s preserves the old file; successful writes decode with the reader's validator; each invalid window is independent except whole-input invalid JSON/NaN. 15-minute stale uses virtual time, as does <30s / ≥30s throttling. Exactly 100 used is exhausted; 99.49/99.5/99.6 remain non-exhausted and show `<1%` remaining. Expired evidence survives empty inputs until replaced or cleared.

File tests include intermediate/target symlinks, FIFO and nonregular lock rejection, old permissions not silently changed, concurrent first creation, umask 0777, complete-key privacy whitelist, failed-before-replace cleanup, both merge orders, stable-lock clear/write ordering and exact temporary-name cleanup (similar names, including a trailing-newline lookalike, retained). Valid future observations are distinguished from corrupt time/reset/changedAt fields: clock rollback preserves the former; otherwise unusable corrupt files can be repaired by a new valid input. The debug executable uses `@testable import HUDCore`; hooks are not available in Release CLI.

Process tests separately time the bridge PID when a producer never gives EOF, then kill/reap the producer. The final Release bridge returned after **1.508849s**. Lock-release tests use a worker that signals **after acquiring the actual stable writer lock**, then SIGKILL that worker; a subsequent bridge succeeds. Valid stdin still prints the current observation when persistence fails due to permissions, symlink or lock contention; silent mode stays empty; closed stdout/EPIPE is handled.

Twenty Release process launches (seconds, includes loading, not just main):

```text
0.005098 0.004833 0.004787 0.004775 0.004684
0.004651 0.004546 0.004666 0.004559 0.004557
0.004585 0.004647 0.004498 0.004590 0.004513
0.004499 0.004460 0.004454 0.004513 0.004498
```

Min / middle sample / max: **0.004454 / 0.004585 / 0.005098 seconds**. These are local synthetic measurements, not a total-wrapper-latency SLA. Wrapper collection waits for EOF before the bridge budget begins. Original-command runtime, loader time, scheduling stalls and wrapper-only descendant behavior are not bounded by it.

Conflicting preview/check/diagnose mode flags are explicitly rejected with exit 2 before AppDelegate or diagnostics initialization; the conflicting-argument tests do not execute the real diagnostic mode. Preview Open Codex is also a no-op. The existing-statusline shell picker starts unselected and requires an explicit choice before generated-script/config-copy actions are available.

The generated wrapper is tested from actual `ClaudeSetup` output: standard JSON decoding and escaped commands round-trip; sh/bash/zsh independent contexts retain stdin (including quotes, dollar/backslash and two trailing newlines), stdout and exit code even when fake bridge exits 7, is non-executable or delays 1s. 512 KiB input is preserved for the original command. No-EOF collection remains running beyond the bridge's budget; process-group SIGTERM cancels synthetic collection/original-command cases. This is **not** evidence of actual Claude cancellation semantics. Command-only replacement and restoration retain padding/refreshInterval/hideVimModeIndicator in synthetic JSON.

### Reproduce without any account

Use a private canonical temporary root (do not use the default snapshot directory):

```sh
V="$(/usr/bin/python3 -c 'import pathlib,tempfile; print(pathlib.Path(tempfile.mkdtemp(prefix="codex-hud-verify-")).resolve())')"
./scripts/check.sh
./scripts/build.sh "$V/Codex HUD.app"
BIN="$V/Codex HUD.app/Contents/MacOS/CodexHUD"
./scripts/verify-claude-bridge.sh "$BIN" "$V/bridge"
./scripts/verify-claude-fixtures.sh "$BIN" "$V/fixtures" # all 11 closed-loop / native / image checks
"$BIN" --check-window "$V/window" > "$V/window.json"
NOW=$(date +%s)
printf '{"rate_limits":{"five_hour":{"used_percentage":100,"resets_at":%d},"seven_day":{"used_percentage":23,"resets_at":%d}}}' "$((NOW+3600))" "$((NOW+86400))" | "$BIN" --claude-statusline-bridge --claude-snapshot-dir "$V/snap"
"$BIN" --check-claude "$V/now" --claude-snapshot-dir "$V/snap" --now "$NOW"
"$BIN" --check-claude "$V/stale" --claude-snapshot-dir "$V/snap" --now "$((NOW+960))"
"$BIN" --check-claude "$V/passed" --claude-snapshot-dir "$V/snap" --now "$((NOW+3601))"
"$BIN" --demo "$V/demo"
./scripts/package.sh "$V/release"
(cd "$V/release" && shasum -a 256 -c CodexHUD-macOS-arm64.zip.sha256)
```

Check JSON uses **nested objects**, not dotted literal keys. A representative subset is:

```json
{"file":"valid","overall":"observed","fiveHour":{"state":"observed","remaining":"0%"},"sevenDay":{"state":"observed","remaining":"77%"},"tabClaudeText":"77%","fiveHourExhaustedHint":true}
```

`render-check.json` independently records logical width, pixel width and backing scale; it asserts equality to 340pt and scale-derived pixels, never “at least 340”. Window checks are recorded in [validation/window-check.json](validation/window-check.json). Build artifacts and detailed fixture evidence remain in the private local verification directory recorded in the task progress file, not committed source.

### Unverified / unsupported matrix

| Scenario | Status |
|---|---|
| Real Claude setup, first API response and observed ≤5s update | **Unverified; user-operated follow-up only** |
| Source field's true account/server freshness, actual shell and cancellation process group | **Unverified** |
| Existing real statusline command and its private configuration | **Unverified; only synthetic commands executed** |
| Clean machine without Xcode/CLT, real GitHub quarantine, actual first-launch Gatekeeper flow, Claude directly calling an unnotarized app | **Unverified**; extraction/binary self-test is not an install pass |
| macOS 13/14/15 | **Unverified**; target/Mach-O metadata checked only |
| Intel | **Unsupported** |
| Physical drag/hover/click/menu and actual small screen | **Unverified**; direct AppKit callbacks plus synthetic 260pt layout are not physical tests |
| Real multi-account/source identification | **Not supported**; stop old source before switching, restore config before removing wrapper |
| Developer ID signing, notarization, Release upload/publication | **Not performed / not authorized** |

A wording search was scoped semantically: “不是账户实时同步” and existing Codex freshness text are not false-positive failures. No new Claude credential/network/subprocess implementation was found. The bridge uses only whitelisted business data under verified private directory descriptors; system library/home API access is not described as forbidden business-data access.

---

## Historical: original 2026-10-04 release validation

Validated on 2026-10-04. The native app builds and reads real local data. **75 behavioral assertions and 14 native window checks passed.** The final manual mouse-interaction pass remains incomplete because the test Mac was locked.

This public record deliberately omits personal quota values, token totals, credit expiry dates, account identifiers and task titles. Documentation screenshots are generated from synthetic data with `--demo`.

## Environment and build

- macOS 26.2, Apple Silicon arm64.
- Swift 6.0.3 with Command Line Tools; no full Xcode or XCTest was required.
- Installed Codex CLI 0.160.0.
- Release build, `Info.plist` validation and strict local code-signature verification passed.
- The distributable strips debug/object-file path information before signing. The final archive is scanned separately before publication.
- The source has no downloaded package dependencies. Behavioral checks and the Release build were run locally; no hosted CI result is claimed.

## Behavioral checks

Run `./scripts/check.sh`. The count refers to assertions, not separate test suites.

Covered behaviors include:

- Weekly in the primary window; no five-hour or model-reserve substitution.
- Waiting for an answer, approval, or both; no double counting as running.
- Unknown/missing status fields, snapshot-to-patch transitions, lost revisions and subagent exclusion.
- Inclusive three-day and 24-hour credit warnings, expired credits and incomplete details.
- Token deltas, repeated snapshots, cached/reasoning subsets, local midnight and Weekly boundaries.
- Partially appended lines, repeated files, copied fork history, file replacement/truncation, counter restarts and future timestamps.
- Unknown Weekly cycles; no calendar-week fallback.
- Outbound task-control and credit-consumption methods rejected by the RPC allowlist.
- Actual test-process pipe timeouts and EOF, and invalid executable overrides.
- Window preferences, compatibility with older settings, transparency bounds and left/right docking geometry on screens with negative coordinates.
- Oversized unfinished JSONL records: memory-bounded skipping, then recovery on a later valid line.
- Oversized complete RPC responses: rejected before decoding.
- Out-of-range dates rejected, and overflowing token totals visibly marked incomplete instead of crashing.

## Native window checks

Run the app with `--check-window OUTPUT_DIRECTORY`. All 14 checks passed against real AppKit windows and rendered pixels.

They cover ordinary/floating window levels, background transparency while keeping foreground text opaque, left/right collapse to a 36 × 108 point tab, expansion to 340 points, leaving/collapsing again, undocking, disabling collapse, hiding/showing and opening settings.

The mode does not synthesize input, connect to an account, save preferences or change the saved window position. It does not establish that all physical mouse events and restart flows were tested. Machine-readable results are in [validation/window-check.json](validation/window-check.json).

## Real data validation

- The official account read returned Weekly quota and complete reset-credit expiry details.
- A real response with known credit count but missing per-credit details produced the expected unverified warning; a later retry returned the complete details.
- The default Desktop IPC v11 observer confirmed a real running local task. The post-hardening diagnostic check also passed with peer-identity validation enabled.
- A separate reader recomputed tokens from the original local JSONL files at the exact frozen cutoff. Today and Weekly totals and all four breakdowns matched.
- An earlier interactive pass exercised the token, task and credit detail pages.
- All five public screenshots were generated without connecting to an account, then visually inspected. No live screenshots or diagnostic dumps are included in the repository.

## Remaining gaps

- The final physical drag, hover, menu/gear clicks, save/restart, reconnect and Open Codex interaction pass was blocked by the Mac lock screen. Native window-state and rendering checks passed, but a complete manual UI pass is not claimed.
- No real task was deliberately put into an approval/input waiting state. Those transitions are covered by fixtures and behavior checks.
- Shared app-server socket mode has not been exercised against a real shared server.
- Other Codex versions, Intel Macs, other macOS releases, remote/cloud task coverage and long-running cross-reset behavior were not validated on actual devices.
- This was a scoped development and security review, not independent penetration testing or notarization.

---

中文摘要：75 项核心行为断言、14 项原生窗口/渲染检查通过，真实额度、逐卡到期时间、任务状态和 Token 已读取并复核。公开仓库不保留个人用量快照；图片使用虚构数据。最后一轮真实鼠标交互仍受锁屏限制，共享 socket 和其他设备/系统版本尚未实机验收。
