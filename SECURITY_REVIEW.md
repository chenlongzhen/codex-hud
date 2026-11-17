# Security review — initial public release

## 2026-11-16 proxy timeout fix

The prior environment allowlist dropped the machine's HTTP proxy, so the validated binary now timed out on this user's current network. A controlled copy differing only by the existing unauthenticated loopback HTTP proxy returned a rate-limit response instead; a subsequent fixed build, after retry-after and with shell proxy variables removed, successfully parsed both windows through the macOS system proxy. This is an actual single-machine dry-run, not a guarantee for all proxy configurations.

`ClaudeProxyConfiguration` reads the public CFNetwork system-proxy dictionary, not Claude settings or credential stores. It selects documented HTTP(S) environment variables first, otherwise a static macOS HTTP(S) proxy, and normalizes only `HTTPS_PROXY` / `NO_PROXY` into the child allowlist. The bootstrap revalidates those normalized values without re-reading system state. Claude/API-key variables, custom CA paths and TLS-verification-disable variables are still not forwarded. URLs with userinfo, invalid hosts/ports/control characters or unexpected components are rejected; PAC is not downloaded/evaluated and SOCKS-only/auto-discovery setups fail visibly rather than silently switching to direct. No raw proxy URL enters report/UI/logging. Common system bypass entries are passed through (`*.domain` becomes `.domain`); full PAC routing and every advanced platform-specific exception are not implemented. Existing system routing is reused, not configured or changed.

Reference: [official Claude proxy documentation](https://code.claude.com/docs/en/network-config.md#proxy-configuration). The fake child receives synthetic proxy values to test the exact expanded allowlist without using real network configuration.

## 2026-11-15 active CLI polling increment (local candidate)

This is an implementation/test record, not a completed independent security certification. Active polling is enabled by default, including upgrades; the first-launch notice and settings toggle disclose it. This section supersedes historical statements below that no Claude subprocess is started.

- Only `ClaudeProbe.swift` creates Claude-related processes. It uses `posix_spawn` with SETSID, CLOEXEC_DEFAULT, reset signal dispositions/mask, a verified empty 0700 cwd, canonical executable/ancestor ownership and permissions, fixed arguments and an explicit environment. No user command string is evaluated. The optional path-detection button may run a fixed `zsh -lc 'command -v claude'`; login-shell startup files remain user-trusted executable code and are disclosed in settings.
- A private same-binary bootstrap, before HUD/settings initialization, requires a session-leader TTY, attaches it via TIOCSCTTY, rebuilds the environment allowlist and execs the validated CLI with `--safe-mode --strict-mcp-config /usage`. It carries no arbitrary CLI arguments. This replaces the experimentally insufficient assumption that dup2 alone acquires a controlling terminal.
- Native helper tests verify the exact child envp, closed inherited descriptors, controlling terminal and separate process group. `CLAUDECODE`, `CLAUDE_CODE_*` and `ANTHROPIC_*` are not forwarded. `DISABLE_AUTOUPDATER=1` is supplied. A node shebang requires a separately validated Node executable.
- Raw terminal output stays in memory. The interpreter rejects over 64 KiB of total terminal data (stricter than the original 1 MiB ceiling); errors export only fixed categories. A monotonic 30s execution budget is followed by group cancellation and up to 2s escalation. Master PTY closes **before waitpid**, preventing macOS tty-output-drain deadlocks. Ordinary parent SIGKILL hangup cleanup is tested, but malicious descendants that detach/ignore signals and kernel freezes are not an absolute guarantee.
- First independent acceptance found two blocking counterexamples despite passing tests: replayed bridge data postponed polling until reset, and lifecycle generation checks discarded UI replies but not already queued disk writes. The corrective design uses an independent monotonic polling deadline, active-only confirmation timestamps, and revocable per-request commit authority propagated into the writer. A short authorization mutex encloses only the final rename, not flock/encoding/fsync: invalidation either follows an already completed commit or prevents it. Actual private-directory tests cover cancellation after returning to the writer, a before-rename barrier, and both clear orderings. Historical first-round packages are not approved by this record.
- Cross-process probe.lock prevents overlapping HUD/one-shot probes. Snapshot writes still use the independent stable .lock and atomic replacement. Schema 2 supports source timestamps and confirmation times without fabricating a bridge run. It reads schema 1 but older HUD builds cannot read schema 2.
- HUD itself does not read credentials/cookies or call an account API. The official CLI still reads its own login state and communicates with Anthropic; safe mode is not a sandbox or an assurance of zero CLI side effects. The CLI may create trust/session state. This build does not read or delete transcript contents. A user-authorized real dry-run used a temporary snapshot directory; probe-transcript metadata was unchanged and the child group was empty afterward.
- Only complete matching private-directory trust prompts with the safe default selection are answered. No other prompts are accepted. No `/exit` command is typed into a potentially active usage panel; after parsing, the process group is terminated instead.
- Preview/check/icon/bridge modes never start real Claude; `--diagnose` explicitly disables probing. Raw account percentages from real tests are kept out of public documentation/screenshots. Synthetic fake executables and preview renders cover regression paths; see [VALIDATION.md](VALIDATION.md).

## Historical: 2026-11-15 Claude observation extension (local candidate)

This section is a scoped implementation record, not a new independent security certification. Historical claims below describe the original release, not real-account tests in this change.

- The native bridge is selected before NSApplication and HUDStore. No Claude command execution, network API, credential/keychain/cookie access or real Claude-settings read/write is added. Only percentages and integer timestamps are retained; cwd/session/workspace fields are dropped.
- Home comes from getpwuid, not HOME. Default and explicit test paths are walked component by component using openat(O_DIRECTORY|O_NOFOLLOW); directory/file owner, type and permissions are checked by fd. Existing objects are never silently chmodded. Only successful mkdirat/new O_EXCL creations have permissions corrected (including umask 0777).
- Snapshot IO uses directory-relative no-follow opens, capped nonblocking reads, a stable .lock, bounded flock retry, exclusive random temporary creation, complete writes/fsync and renameat. renameat takes no no-follow flags. Cleanup uses fstatat(AT_SYMLINK_NOFOLLOW)/unlinkat, exact PID/8-hex basenames, at most 512 examined entries and 16 removals. Clear uses the same lock and never deletes it.
- All decoded and encoded timestamps are bounded. Future observations on clock rollback are preserved rather than emitting self-invalid files. Expired windows remain evidence until replaced/cleared. Corrupt reads clear display numbers. A malicious same-UID program with arbitrary control of private directories is outside this boundary.
- Process watchdog and stdin deadlines use monotonic time. Valid stdin stdout does not depend on persistence; short writes/EINTR, EPIPE/SIGPIPE and closed stdout are handled. The 2s main budget assumes scheduling, excludes loader time and does not promise behavior under SIGKILL/crash/freeze or atomic output on arbitrary fds.
- Store uses generation tokens, enabled rechecks and a single outstanding read. Disable/clear/preview lifecycle invalidates pending results. Preview/check modes do not load real settings, read default snapshots, write configuration, clear the real directory, change login items or connect/reconnect data sources. Preview copy actions are disabled too.
- Existing-statusline support is a pure text generator using standard JSON decoding and explicit user-selected shell. HUD never executes the pasted string. The user-saved wrapper runs the original command in an independent shell -c context; inherited privileges and original logging remain the user's trust boundary. Input waits for EOF in memory with no wrapper size/time bound and cannot preserve NUL. Group SIGTERM is synthetic-tested; wrapper-only termination and actual Claude cancellation are not guaranteed. Backup/restore original command and configuration before removing the wrapper; retain other statusLine fields/timers.
- The local package includes the project MIT LICENSE; no third-party implementation code or package dependency was added. Packaging resolves/rejects unsafe/nonempty/install destinations before writing, restricts this candidate to a private temporary boundary, verifies actual Mach-O minimum OS, arm64 and system-only dependencies, extracts and self-tests. Ad-hoc signature only; no notarization, install, publication, quarantine removal or security bypass.

Tests and explicit unverified items are recorded in [VALIDATION.md](VALIDATION.md). The prior Codex account RPC whitelist, token scanner and task data semantics are unchanged.


Reviewed on 2026-10-04. **No unresolved critical or high-severity issue was identified in the reviewed scope.** Publication privacy and local-input robustness findings were fixed before the first public commit. This is a source and artifact review with targeted regression tests, not an independent penetration test or a guarantee against vulnerabilities.

Scope: Swift/SwiftUI/AppKit code, local subprocess and Unix-socket boundaries, read-only SQLite/session access, settings, diagnostics, shell build helpers, documentation and release artifacts. The security workflow used did not provide a Swift-specific checklist; the review therefore used direct code inspection and the platform reference cited below.

## Findings and fixes

| ID | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| SEC-001 | Medium | Development evidence contained real usage totals and credit expiry dates. A compiled executable also retained private build paths in debug symbols. | Real evidence was removed from the public file set before Git initialization. Screenshots now use synthetic data. Release builds strip debug/object-file paths before signing; source and binary artifacts are checked for private paths and identifiers. |
| SEC-002 | Medium | An oversized JSONL line could grow the scanner's pending buffer and spend excessive time repeatedly searching it. A complete oversized RPC response could reach JSON decoding before the old trailing limit check. | A 16 MiB JSONL record limit skips the remainder through its newline and marks the report incomplete. A 32 MiB RPC buffer limit is checked before decoding. Regression fixtures verify rejection and scanner recovery. |
| SEC-003 | Medium | Malformed extreme timestamps and token counts could overflow display or arithmetic conversions and terminate the HUD. | Dates outside the supported epoch range are rejected. Checked/saturating addition prevents arithmetic traps and adds an explicit incomplete-data issue. Regression fixtures reproduce these cases. |
| SEC-004 | Low | Checking socket path ownership alone did not confirm the identity of the connected peer after a possible path replacement. | The default Desktop observer additionally calls `getpeereid` after connection, requires the current user's ID, and sets close-on-exec. Updates for undiscovered conversation IDs are ignored. |
| SEC-005 | Low | Diagnostics reused a task-source string that could include upstream server error text. | Diagnostic source labels are fixed identifiers; arbitrary upstream error text is not exported. Diagnostics still contain real usage and timestamps and are documented as private. |

## Source evidence

- RPC method allowlist and direct process launch: [AppServer.swift:10](Sources/HUDCore/AppServer.swift#L10). Only initialization, quota reads and required shared-task reads are permitted; model/task/credit mutation methods are absent. No shell interpolation is used for launching the CLI.
- RPC size limit before JSON parsing: [AppServer.swift:123](Sources/HUDCore/AppServer.swift#L123).
- Bounded session parsing and recovery: [Tokens.swift:137](Sources/HUDCore/Tokens.swift#L137).
- Checked token arithmetic and incomplete-data marking: [Tokens.swift:19](Sources/HUDCore/Tokens.swift#L19), [Tokens.swift:70](Sources/HUDCore/Tokens.swift#L70).
- Date validation and complete-credit checks: [Quota.swift:39](Sources/HUDCore/Quota.swift#L39), [Quota.swift:61](Sources/HUDCore/Quota.swift#L61).
- Connected peer check: [DesktopObserver.swift:98](Sources/HUDCore/DesktopObserver.swift#L98). The platform behavior is documented in [Apple's `getpeereid` manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getpeereid.3.html).
- Read-only SQLite handles and fixed SQL statements: [LocalTasks.swift:30](Sources/HUDCore/LocalTasks.swift#L30).
- Fixed diagnostic source labels: [Diagnostics.swift:22](Sources/CodexHUD/Diagnostics.swift#L22).
- UUID validation before a task deep link: [HUDStore.swift:289](Sources/CodexHUD/HUDStore.swift#L289).
- Release debug-symbol stripping: [scripts/build.sh:11](scripts/build.sh#L11).
- Synthetic screenshot data: [Demo.swift:4](Sources/CodexHUD/Demo.swift#L4). Demo mode does not start data connections or scan local sessions.

## Confirmed boundaries

- The HUD does not open browser-cookie stores or credential files. The installed Codex CLI uses its existing login and configuration for account reads.
- The HUD has no upload endpoint, analytics SDK, auto-updater or third-party package dependency. It starts a Codex sidecar for account requests; those are not an offline operation. The sidecar is launched with analytics disabled, and its stderr is discarded rather than persisted.
- Session contents and Desktop history can pass through memory. Only token events and task/status metadata are retained by the application logic, and no conversation-content cache is written to disk.
- Settings and window position are local. There is no API-key field. Normal macOS user-level filesystem access applies; the app is not sandboxed.
- Desktop protocol input is capped at 256 MiB per frame because snapshots may contain substantial history. This is a finite bound, but large histories can still cause a noticeable memory spike. Protocol changes can make task status unavailable.
- A custom executable and an advanced shared socket are user-selected trust inputs. The local peer check described above applies to the default Desktop observer. It does not defend against malicious programs already running as the same user or a malicious Codex installation.
- No repository workflow is installed by this release. Git author metadata uses the owner's GitHub no-reply address.

## Verification

- 75 behavioral assertions passed, including malformed-input, timeout/EOF and forbidden-operation checks.
- 14 AppKit window-state/render checks passed; the manual-interaction limitation is recorded in [VALIDATION.md](VALIDATION.md).
- Real account data and Desktop status remained available after hardening.
- Release code signature and property-list checks passed.
- Gitleaks 8.30.1 found no secrets in the public source set. Committed history is also scanned locally before the first push; scanned contents are not uploaded to a scanning service.
- Images were generated from synthetic fixtures and visually inspected; private runtime JSON, preferences, databases, session logs and local build caches are excluded from Git.

中文摘要：公开前已移除真实用量/到期信息和二进制中的本机调试路径，修复超长记录/响应处理、极端数值溢出、socket 对端身份校验及诊断输出边界。范围内未发现仍未解决的严重或高危问题。任务状态依赖可关闭的实验接口；应用未公证，也不提供同一 macOS 用户内的恶意进程隔离。
