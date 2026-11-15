import AppKit
import Foundation
import HUDCore

@main
struct CodexHUDMain {
    private static func runProbeOnce() -> Int32 {
        var options = ClaudeProbe.Options(), dryRun = false, index = 1
        let args = CommandLine.arguments
        var seen = Set<String>()
        while index < args.count {
            let flag = args[index]
            guard seen.insert(flag).inserted else { return 2 }
            switch flag {
            case "--probe-claude-once": break
            case "--dry-run": dryRun = true
            case "--claude-executable", "--claude-snapshot-dir", "--claude-probe-dir", "--claude-config-dir":
                index += 1
                guard index < args.count, args[index].hasPrefix("/"), !args[index].utf8.contains(0) else { return 2 }
                switch flag {
                case "--claude-executable": options.executable = args[index]
                case "--claude-snapshot-dir": options.snapshotDirectory = args[index]
                case "--claude-probe-dir": options.probeDirectory = args[index]
                default: options.configDirectory = args[index]
                }
            default: return 2
            }
            index += 1
        }
        let runner = ClaudeProbe(), permit = ClaudeCommitPermit()
        let token = runner.cancellationToken
        // Async-signal-safe Dispatch sources wake the executor's bounded cancellation loop.
        let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { permit.invalidate(); runner.cancel() }; source.resume(); return source
        }
        defer { sources.forEach { $0.cancel() } }
        var report = runner.run(options, cancellationToken: token)
        let now = Int64(Date().timeIntervalSince1970)
        if report.result.status == .success {
            let existing = ClaudeSnapshotFile.read(directory: options.snapshotDirectory, now: now).snapshot
            report.result = ClaudeSnapshotMerge.usableProbe(report.result, existing: existing, now: now)
        }
        var object = report.json
        if !dryRun, report.result.status == .success {
            let written = ClaudeSnapshotFile.write(probe: (report.result.fiveHour, report.result.sevenDay), directory: options.snapshotDirectory, now: now, permit: permit)
            object["writeStatus"] = written.rawValue
            if written != .written { object["status"] = written == .cancelled ? "cancelled" : "writeFailed" }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return 1 }
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        return object["status"] as? String == "success" ? 0 : 1
    }
    @MainActor static func main() {
        ClaudeProbe.executePTYChildIfRequested(CommandLine.arguments)
        let modes = ["--make-icon", "--diagnose", "--demo", "--check-window", "--check-claude", "--claude-statusline-bridge", "--probe-claude-once"]
        guard modes.filter({ CommandLine.arguments.contains($0) }).count <= 1 else { exit(2) }
        if CommandLine.arguments.contains("--claude-statusline-bridge") { ClaudeBridge.run(arguments: CommandLine.arguments) }
        if CommandLine.arguments.contains("--probe-claude-once") { exit(runProbeOnce()) }
        if let index = CommandLine.arguments.firstIndex(of: "--make-icon"), CommandLine.arguments.count > index + 1 {
            do { try makeIconSet(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])) } catch { fputs("Icon generation failed\n", stderr); exit(1) }
        } else if CommandLine.arguments.contains("--diagnose") {
            Task { @MainActor in exit(await runDiagnostics()) }
            dispatchMain()
        } else {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            application.run()
            withExtendedLifetime(delegate) {}
        }
    }
}
