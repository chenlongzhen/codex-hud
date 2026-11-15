import AppKit
import Foundation

@main
struct CodexHUDMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--claude-statusline-bridge") { ClaudeBridge.run(arguments: CommandLine.arguments) }
        let modes = ["--make-icon", "--diagnose", "--demo", "--check-window", "--check-claude"]
        guard modes.filter({ CommandLine.arguments.contains($0) }).count <= 1 else { exit(2) }
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
