# Security review — initial public release

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
