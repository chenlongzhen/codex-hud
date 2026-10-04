# Validation record

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
