import Foundation
import Darwin
#if DEBUG
@testable import HUDCore
#else
import HUDCore
#endif

/// Only copied test executables enter this branch; production never has a fake-process mode.
func runProbeFixtureIfNeeded() -> Bool {
    guard CommandLine.arguments.first?.hasSuffix("fake-claude") == true, CommandLine.arguments.dropFirst() == ["--safe-mode", "--strict-mcp-config", "/usage"] else { return false }
    let binary = URL(fileURLWithPath: CommandLine.arguments[0])
    let fixtureURL = binary.deletingLastPathComponent().appendingPathComponent("fixture.json")
    guard let data = try? Data(contentsOf: fixtureURL), let fixture = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { exit(3) }
    let record = fixture["record"]!
    var inherited: [Int] = []
    for fd in 3..<256 where fcntl(Int32(fd), F_GETFD) != -1 { inherited.append(fd) }
    let tty = open("/dev/tty", O_RDWR); if tty >= 0 { close(tty) }
    let info: [String: Any] = ["env": ProcessInfo.processInfo.environment, "fds": inherited, "tty": tty >= 0,
                               "cwd": FileManager.default.currentDirectoryPath, "pid": getpid(), "pgid": getpgrp()]
    try! JSONSerialization.data(withJSONObject: info).write(to: URL(fileURLWithPath: record))
    switch fixture["mode"] ?? "success" {
    case "hang": signal(SIGTERM, SIG_IGN); while true { pause() }
    case "overflow": for _ in 0..<300 { FileHandle.standardOutput.write(Data(repeating: 65, count: 8192)) }; while true { pause() }
    case "login": print("Not logged in. Please run /login"); fflush(stdout)
    case "trust-wrong": print("Accessing workspace:\n/another/path\nQuick safety check: Do you trust this folder?\n❯ No, exit\nYes, I trust this folder"); fflush(stdout); while true { pause() }
    default:
        print("Current session\n8% used\nResets in an unknown format\nCurrent week (all models)\n23% used\nResets in an unknown format\nApproximate\n13% used")
        fflush(stdout); while true { pause() }
    }
    return true
}

#if DEBUG
func testClaudeProbeExecutionAndSchedule() throws {
    let fm = FileManager.default
    let root = try claudeTemporaryDirectory()
    // Keep test artifacts for traceable failures; no real Claude or user configuration is touched.
    let exe = root.appendingPathComponent("fake-claude")
    let current = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    try fm.copyItem(at: current, to: exe); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exe.path)
    let record = root.appendingPathComponent("record.json"), fixture = root.appendingPathComponent("fixture.json")
    func mode(_ mode: String) throws { try JSONSerialization.data(withJSONObject: ["mode": mode, "record": record.path]).write(to: fixture) }
    let options = ClaudeProbe.Options(executable: exe.path, snapshotDirectory: root.appendingPathComponent("snapshot").path, probeDirectory: root.appendingPathComponent("cwd").path)
    try mode("success")
    setenv("CLAUDECODE", "test-injected", 1); setenv("ANTHROPIC_API_KEY", "test-not-a-key", 1); setenv("CLAUDE_CODE_FOO", "test-injected", 1)
    let leakedFD = open(root.appendingPathComponent("should-not-leak").path, O_CREAT | O_RDWR, 0o600)
    let runner = ClaudeProbe(timeout: 1.5, grace: 0.1)
    let success = runner.run(options)
    if leakedFD >= 0 { close(leakedFD) }
    expectEqual(success.result.status, .success)
    expectEqual(success.result.fiveHour?.usedPercentage, 8)
    expectEqual(success.result.sevenDay?.usedPercentage, 23)
    let info = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
    let env = info["env"] as! [String: String]
    // Foundation may add this one platform variable after exec; the process-level C helper
    // separately checks the exact initial envp before loading Foundation.
    expectEqual(Set(env.keys).subtracting(["__CF_USER_TEXT_ENCODING"]), Set(["HOME", "USER", "LOGNAME", "PATH", "TERM", "LANG", "COLUMNS", "LINES", "DISABLE_AUTOUPDATER"]))
    expectEqual(env["DISABLE_AUTOUPDATER"], "1")
    expectEqual(info["fds"] as? [Int], [])
    expectEqual(info["tty"] as? Bool, true)
    expectEqual(info["pid"] as? Int, info["pgid"] as? Int)
    expectEqual(info["cwd"] as? String, options.probeDirectory)
    expectEqual(kill(success.childPID!, 0), -1)
    expectEqual(kill(-success.childPID!, 0), -1)
    try mode("hang")
    let hung = ClaudeProbe(timeout: 0.3, grace: 0.1).run(options)
    expectEqual(hung.result.status, .timeout); expectEqual(hung.elapsed < 2, true)
    expectEqual(kill(-hung.childPID!, 0), -1)
    try mode("overflow")
    expectEqual(ClaudeProbe(timeout: 3, grace: 0.1).run(options).result.status, .outputOverflow)
    try mode("login")
    expectEqual(runner.run(options).result.status, .loginRequired)
    try mode("trust-wrong")
    expectEqual(runner.run(options).result.status, .trustFailed)
    try mode("hang")
    let cancelled = ClaudeProbe(timeout: 4, grace: 0.1)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancelled.cancel() }
    expectEqual(cancelled.run(options).result.status, .cancelled)
    let pending = ClaudeProbe(timeout: 1, grace: 0.1)
    let pendingToken = pending.cancellationToken; pending.cancel()
    expectEqual(pending.run(options, cancellationToken: pendingToken).result.status, .cancelled)
    let held = try ClaudeSnapshotFile.acquireProbeLock(directory: options.snapshotDirectory)!
    expectEqual(runner.run(options).result.status, .busy); close(held)
    try Data().write(to: URL(fileURLWithPath: options.probeDirectory!).appendingPathComponent("unexpected"))
    expectEqual(runner.run(options).result.status, .probeDirNotEmpty)
    try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: exe.path)
    expectEqual(runner.run(options).result.status, .untrustedExecutable)
    expectEqual(ClaudeProbe.validatedExecutable("relative/path"), nil)
    expectEqual(ClaudeProbe.validatedExecutable("/usr/bin/true\0oops"), nil)

    let old = try JSONDecoder().decode(HUDConfiguration.self, from: Data("{}".utf8))
    expectEqual(old.claudeProbeEnabled, true); expectEqual(old.claudeProbeInterval, 900); expectEqual(old.claudeProbeNoticeSeen, false)
    let badInterval = try JSONDecoder().decode(HUDConfiguration.self, from: Data("{\"claudeProbeInterval\":1}".utf8))
    expectEqual(badInterval.claudeProbeInterval, 900)
    let now: Int64 = 1_800_000_000
    var s = ClaudeProbeSchedule()
    s.configure(enabled: true, interval: 900, uptime: 100)
    expectEqual(s.begin(uptime: 109, now: now, snapshot: nil), false)
    expectEqual(s.begin(uptime: 110, now: now, snapshot: nil), true)
    expectEqual(s.begin(uptime: 111, now: now, snapshot: nil, manual: true), false)
    s.finish(result: .init(status: .success), uptime: 111, now: now)
    expectEqual(s.nextAttempt, 1011); expectEqual(s.manualAllowed(uptime: 169), false)
    expectEqual(s.begin(uptime: 170, now: now, snapshot: nil, manual: true), true)
    s.finish(result: .init(status: .timeout), uptime: 171, now: now)
    expectEqual(s.nextAttempt, 1971)
    for i in 0..<6 { s.finish(result: .init(status: .timeout), uptime: Double(200 + i), now: now) }
    expectEqual(s.nextAttempt, 14605)
    s.finish(result: .init(status: .rateLimited, retryAfter: now + 20_000), uptime: 1000, now: now)
    expectEqual(s.nextAttempt, 21000)
    s.finish(result: .init(status: .notFound), uptime: 1000, now: now)
    expectEqual(s.blocked, true); expectEqual(s.nextAttempt, nil)
    expectEqual(s.begin(uptime: 100_000, now: now, snapshot: nil), false)
    expectEqual(s.begin(uptime: 100_000, now: now, snapshot: nil, manual: true), true)
    s.finish(result: .init(status: .success), uptime: 100_001, now: now)
    s.sleep(); expectEqual(s.begin(uptime: 200_000, now: now, snapshot: nil), false)
    s.wake(uptime: 200_000); expectEqual(s.nextAttempt, 200_030)
    s.configure(enabled: false, interval: 900, uptime: 0)
    expectEqual(s.begin(uptime: 1000, now: now, snapshot: nil, manual: true), false)
    s.configure(enabled: true, interval: 900, uptime: 0)
    let w = ClaudeWindow(usedPercentage: 8, resetsAt: now + 3600, changedAt: now - 800, confirmedAt: now - 10)
    let snapshot = ClaudeSnapshot(bridgeSeenAt: now - 10, fiveHour: w, sevenDay: w)
    expectEqual(s.begin(uptime: 10, now: now, snapshot: snapshot), true)
    expectEqual(s.nextAttempt, nil)
    s.finish(result: .init(status: .success), uptime: 10, now: now)
    expectEqual(s.begin(uptime: 909, now: now + 899, snapshot: snapshot), false)
    expectEqual(s.begin(uptime: 910, now: now + 900, snapshot: snapshot), true)

    // F1: use the actual bridge parser+merge each minute, not a static snapshot.
    // A replay must not change the independent active start sequence across five hours.
    let raw = Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":8,\"resets_at\":\(now + 18000)},\"seven_day\":{\"used_percentage\":23,\"resets_at\":\(now + 604800)}}}".utf8)
    var cached: ClaudeSnapshot?, replayed = ClaudeProbeSchedule(), withoutBridge = ClaudeProbeSchedule()
    replayed.configure(enabled: true, interval: 900, uptime: 0)
    withoutBridge.configure(enabled: true, interval: 900, uptime: 0)
    var starts: [Int] = [], baselineStarts: [Int] = []
    for second in 0...18000 {
        let clock = now + Int64(second)
        if second % 60 == 0 {
            let input = ClaudeStatuslineInput.parse(raw, now: clock)!
            if let next = try ClaudeSnapshotMerge.merge(existing: cached, input: input, now: clock) { cached = next }
        }
        if replayed.begin(uptime: Double(second), now: clock, snapshot: cached) {
            starts.append(second); replayed.finish(result: .init(status: .success), uptime: Double(second), now: clock)
        }
        if withoutBridge.begin(uptime: Double(second), now: clock, snapshot: nil) {
            baselineStarts.append(second); withoutBridge.finish(result: .init(status: .success), uptime: Double(second), now: clock)
        }
        if [960, 3600, 17940].contains(second) {
            expectEqual(ClaudeWindowState.evaluate(window: cached?.fiveHour, now: clock), .stale)
            expectEqual(cached?.fiveHour?.confirmedAt, nil)
        }
    }
    expectEqual(starts, baselineStarts)
    expectEqual(starts, Array(stride(from: 10, through: 18000, by: 900)))
}
#endif
