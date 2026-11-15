import Foundation
import Darwin
#if DEBUG
@testable import HUDCore
#else
import HUDCore
#endif

func claudeTemporaryDirectory() throws -> URL {
    guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw ClaudeReadFailure.ioError }
    let base = String(cString: canonical); free(canonical)
    let root = URL(fileURLWithPath: base).appendingPathComponent("codex-hud-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}
func removeClaudeTestDirectory(_ url: URL) throws {
    // Verify the absolute deletion target, including symlink resolution, before recursive cleanup.
    guard let resolved = realpath(url.path, nil) else { throw ClaudeReadFailure.untrustedLocation }
    let absolute = String(cString: resolved); free(resolved)
    guard url.path.hasPrefix("/"), url.lastPathComponent.hasPrefix("codex-hud-test-"), absolute == url.path else { throw ClaudeReadFailure.untrustedLocation }
    try FileManager.default.removeItem(at: url)
}
#if DEBUG
func testClaudeSnapshotFiles() throws {
    let root = try claudeTemporaryDirectory(); defer { try? removeClaudeTestDirectory(root) }
    let dir = root.appendingPathComponent("snap").path, now = claudeTestNow
    let target = URL(fileURLWithPath: dir).appendingPathComponent("snapshot.json")
    let lockPath = URL(fileURLWithPath: dir).appendingPathComponent(".lock").path
    func mode(_ path: String) -> Int { var info = stat(); _ = lstat(path, &info); return Int(info.st_mode & 0o777) }
    expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now), .absent)
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now), .written)
    expectEqual(mode(dir), 0o700); expectEqual(mode(target.path), 0o600); expectEqual(mode(lockPath), 0o600)
    let saved = try Data(contentsOf: target)
    expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now).snapshot, try ClaudeSnapshot.decode(saved, now: now))
    expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now + 960).snapshot?.fiveHour?.changedAt, now)
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now + 29), .throttled)
    expectEqual(try Data(contentsOf: target), saved)
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now + 30), .written)
    let baseline = try Data(contentsOf: target)
    enum Injected: Error { case failure }
    expectEqual(ClaudeSnapshotFile.writeForTesting(input: sampleClaudeInput(five: 50), directory: dir, now: now + 60, beforeReplace: { throw Injected.failure }), .refused)
    expectEqual(try Data(contentsOf: target), baseline)
    expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("snapshot.json.tmp.") }.count, 0)
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(five: 50), directory: dir, now: now + 60), .written)
    // Lock worker signals only after it really acquired the stable lock.
    let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        _ = ClaudeSnapshotFile.writeForTesting(input: sampleClaudeInput(five: 51), directory: dir, now: now + 90, beforeReplace: { ready.signal(); release.wait() })
        finished.signal()
    }
    expectEqual(ready.wait(timeout: .now() + 5), .success)
    let started = DispatchTime.now().uptimeNanoseconds
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(five: 52), directory: dir, now: now + 91), .lockBusy)
    expectEqual(DispatchTime.now().uptimeNanoseconds - started >= 290_000_000, true)
    expectEqual(ClaudeSnapshotFile.clear(directory: dir), false)
    release.signal(); expectEqual(finished.wait(timeout: .now() + 5), .success)
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(five: 52), directory: dir, now: now + 120), .written)
    for ahead in [Int64(120), 301] {
        let future = ClaudeSnapshot(bridgeSeenAt: now + ahead, fiveHour: ClaudeWindow(usedPercentage: 42, resetsAt: now + 3600, changedAt: now + ahead))
        try future.encoded(now: now + ahead).write(to: target)
        expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now), .clockSkew)
        expectEqual(try Data(contentsOf: target), try future.encoded(now: now + ahead))
        if ahead > 300 { expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now), .failed(.clockSkew)) }
    }
    for invalidTime in [
        "{\"schema\":1,\"bridgeSeenAt\":1}",
        "{\"schema\":1,\"bridgeSeenAt\":1800000000,\"fiveHour\":{\"usedPercentage\":42,\"resetsAt\":1800003600,\"changedAt\":1800000001}}",
        "{\"schema\":1,\"bridgeSeenAt\":1800000000,\"fiveHour\":{\"usedPercentage\":42,\"resetsAt\":9223372036854775807,\"changedAt\":1800000000}}"
    ] {
        try Data(invalidTime.utf8).write(to: target)
        expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now), .failed(.clockSkew))
        expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now), .written)
        expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now).snapshot?.fiveHour?.usedPercentage, 42)
    }
    for text in ["{", "{\"schema\":2,\"bridgeSeenAt\":1800000000}", "{\"schema\":1,\"bridgeSeenAt\":1800000000,\"unknown\":1}", "{\"schema\":true,\"bridgeSeenAt\":1800000000}"] {
        try Data(text.utf8).write(to: target)
        expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now).snapshot, nil)
        expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now), .written)
    }
    try Data(repeating: 0x20, count: 16 * 1024 + 1).write(to: target)
    expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now), .failed(.tooLarge))
    try saved.write(to: target)
    _ = chmod(target.path, 0o644)
    expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now), .failed(.permissions))
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now), .refused)
    expectEqual(mode(target.path), 0o644)
    _ = chmod(target.path, 0o600)
    _ = chmod(dir, 0o755)
    expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now), .failed(.untrustedLocation))
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now), .refused)
    expectEqual(mode(dir), 0o755); _ = chmod(dir, 0o700)
    // Verified explicit basename target; replacing the fixture is intended.
    expectEqual(target.path, dir + "/snapshot.json"); try FileManager.default.removeItem(at: target)
    let victim = root.appendingPathComponent("victim"); try Data("untouched".utf8).write(to: victim)
    expectEqual(symlink(victim.path, target.path), 0)
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now), .refused)
    expectEqual(ClaudeSnapshotFile.clear(directory: dir), false)
    expectEqual(try String(contentsOf: victim, encoding: .utf8), "untouched")
    try FileManager.default.removeItem(at: target)
    expectEqual(mkfifo(target.path, 0o600), 0)
    expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now), .failed(.notRegularFile))
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now), .refused)
    try FileManager.default.removeItem(at: target)
    let linked = root.appendingPathComponent("linked")
    expectEqual(symlink(dir, linked.path), 0)
    expectEqual(ClaudeSnapshotFile.read(directory: linked.path, now: now), .failed(.untrustedLocation))
    let intermediate = root.appendingPathComponent("via")
    expectEqual(symlink(root.path, intermediate.path), 0)
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: intermediate.appendingPathComponent("new").path, now: now), .refused)
    // Reject nonregular lock without changing it.
    expectEqual(lockPath, dir + "/.lock"); try FileManager.default.removeItem(atPath: lockPath)
    expectEqual(mkfifo(lockPath, 0o600), 0)
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now), .refused)
    try FileManager.default.removeItem(atPath: lockPath)
    let oldMask = umask(0o777)
    let masked = root.appendingPathComponent("masked").path
    let maskedResult = ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: masked, now: now)
    _ = umask(oldMask)
    expectEqual(maskedResult, .written)
    expectEqual(mode(masked), 0o700); expectEqual(mode(masked + "/.lock"), 0o600); expectEqual(mode(masked + "/snapshot.json"), 0o600)
    let parallel = root.appendingPathComponent("parallel").path
    let group = DispatchGroup()
    for _ in 0..<20 { group.enter(); DispatchQueue.global().async { _ = ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: parallel, now: now); group.leave() } }
    expectEqual(group.wait(timeout: .now() + 10), .success)
    expectEqual(ClaudeSnapshotFile.read(directory: parallel, now: now).snapshot?.fiveHour?.usedPercentage, 42)
    for order in [true, false] {
        _ = ClaudeSnapshotFile.clear(directory: dir)
        let a = claudeInput("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":42,\"resets_at\":\(now + 3600)}}}")!
        let b = claudeInput("{\"rate_limits\":{\"seven_day\":{\"used_percentage\":23,\"resets_at\":\(now + 86400)}}}")!
        _ = ClaudeSnapshotFile.write(input: order ? a : b, directory: dir, now: now)
        _ = ClaudeSnapshotFile.write(input: order ? b : a, directory: dir, now: now + 1)
        let result = ClaudeSnapshotFile.read(directory: dir, now: now + 1).snapshot
        expectEqual(result?.fiveHour?.usedPercentage, 42); expectEqual(result?.sevenDay?.usedPercentage, 23)
    }
    let cleanupNames = ["snapshot.json.tmp.123.abcdef12", "snapshot.json.tmp.123.abcdef12.bak", "snapshot.json.tmp.123.abcdef12\n", "snapshot.json.tmp.notes", "other"]
    for name in cleanupNames {
        let file = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try Data("keep?".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(now - 120))], ofItemAtPath: file.path)
    }
    _ = ClaudeSnapshotFile.write(input: sampleClaudeInput(five: 60), directory: dir, now: now + 10)
    expectEqual(FileManager.default.fileExists(atPath: dir + "/" + cleanupNames[0]), false)
    for name in cleanupNames.dropFirst() { expectEqual(FileManager.default.fileExists(atPath: dir + "/" + name), true) }
    var lockInfo = stat(); _ = lstat(lockPath, &lockInfo)
    expectEqual(ClaudeSnapshotFile.clear(directory: dir), true)
    expectEqual(ClaudeSnapshotFile.read(directory: dir, now: now + 20), .absent)
    var afterClear = stat(); _ = lstat(lockPath, &afterClear)
    expectEqual(lockInfo.st_ino, afterClear.st_ino)
    expectEqual(ClaudeSnapshotFile.write(input: sampleClaudeInput(), directory: dir, now: now + 20), .written)
    expectEqual(ClaudeSnapshotFile.clear(directory: dir), true)
}
#endif
