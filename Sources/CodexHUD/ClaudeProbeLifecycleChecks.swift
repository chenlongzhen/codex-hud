#if DEBUG
import Foundation
import Darwin
import HUDCore

/// Regression for independent acceptance F2. All paths are new private synthetic fixtures;
/// preview hooks replace process execution and destination, NOT production merge/write logic.
@MainActor func claudeProbeCommitChecks() async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    guard let real = realpath(FileManager.default.temporaryDirectory.path, nil) else { return ["probeCommitFixtureCreated": false] }
    let root = String(cString: real) + "/codex-hud-commit-" + UUID().uuidString
    free(real)
    do {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for action in ["disable", "probe-disable", "settings", "stop", "sleep", "preview-save", "clear", "clear-after-commit"] {
            let directory = root + "/" + action
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let lock = open(directory + "/.lock", O_CREAT | O_RDWR, 0o600)
            guard lock >= 0, flock(lock, LOCK_EX) == 0 else { checks["probeCommit_" + action] = false; if lock >= 0 { close(lock) }; continue }
            let subject = HUDStore(settings: .init(), isPreview: true), reader = ClaudeSnapshotReader()
            let now = Int64(Date().timeIntervalSince1970)
            var entered = false, clearEntered = false, written: ClaudeWriteResult?
            subject.claudeProbeForTesting = { .init(result: .init(status: .success, fiveHour: .init(usedPercentage: 8, resetsAt: now + 3600)), elapsed: 0) }
            subject.claudeProbeWriteForTesting = { result, permit in
                entered = true
                let result = await reader.write(probe: result, directory: directory, now: now, permit: permit)
                written = result
                return result
            }
            subject.claudeClearForTesting = { clearEntered = true; return await reader.clear(directory: directory) }
            subject.startProbeForTesting(); subject.requestClaudeProbe(manual: true)
            for _ in 0..<10000 where !entered { await Task.yield() }
            let absentBefore = ClaudeSnapshotFile.read(directory: directory, now: now).snapshot == nil
            if action == "disable" { var value = subject.settings; value.claudeEnabled = false; try subject.applyWindowSettings(value) }
            if action == "probe-disable" { var value = subject.settings; value.claudeProbeEnabled = false; try subject.applyClaudeProbeSettings(value) }
            if action == "settings" { var value = subject.settings; value.claudeConfigDir = "/synthetic-new-source"; try subject.applyClaudeProbeSettings(value) }
            if action == "stop" { subject.stop() }
            if action == "sleep" { subject.probeSleep() }
            if action == "preview-save" { try subject.applySettings(subject.settings) }
            var clearing: Task<Bool, Never>?
            if action == "clear" {
                clearing = Task { await subject.clearClaude() }
                for _ in 0..<10000 where !clearEntered { await Task.yield() }
            }
            flock(lock, LOCK_UN); close(lock)
            for _ in 0..<100000 where subject.claudeProbing { await Task.yield() }
            if action == "clear-after-commit" {
                let existed = ClaudeSnapshotFile.read(directory: directory, now: now).snapshot != nil
                let cleared = await subject.clearClaude()
                checks["probeCommit_" + action] = entered && absentBefore && existed && cleared && written == .written && ClaudeSnapshotFile.read(directory: directory, now: now).snapshot == nil
            } else {
                let cleared = await clearing?.value ?? true
                checks["probeCommit_" + action] = entered && absentBefore && cleared && !subject.claudeProbing && written == .cancelled && subject.claudeProbeReport == nil && ClaudeSnapshotFile.read(directory: directory, now: now).snapshot == nil
            }
        }
    } catch { checks["probeCommitFixtureCreated"] = false }
    return checks
}
#endif
