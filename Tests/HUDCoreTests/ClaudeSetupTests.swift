import Foundation
import Darwin
import HUDCore

func runClaudeTestProcess(_ executable: String, _ arguments: [String], input: Data = Data()) throws -> (Int32, Data, Data) {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
    try process.run()
    try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errors = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, output, errors)
}
func testClaudeSetupTextAndWrappers() throws {
    let root = try claudeTemporaryDirectory(); defer { try? removeClaudeTestDirectory(root) }
    let special = root.appendingPathComponent("a b/it's $HOME")
    try FileManager.default.createDirectory(at: special, withIntermediateDirectories: true)
    let fake = special.appendingPathComponent("CodexHUD"), arguments = root.appendingPathComponent("arguments")
    try ("#!/bin/sh\nprintf '%s\\n' \"$@\" > " + ClaudeSetup.shellQuote(arguments.path) + "\n").write(to: fake, atomically: true, encoding: .utf8)
    _ = chmod(fake.path, 0o700)
    let command = ClaudeSetup.bridgeCommand(executable: fake.path)
    let json = ClaudeSetup.statusLineJSON(command: command)
    let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: [String: String]]
    expectEqual(decoded["statusLine"]?["command"], command)
    let run = try runClaudeTestProcess("/bin/sh", ["-c", decoded["statusLine"]!["command"]!])
    expectEqual(run.0, 0)
    expectEqual(try String(contentsOf: arguments, encoding: .utf8), "--claude-statusline-bridge\n")
    let bridgeInput = root.appendingPathComponent("bridge-input"), originalInput = root.appendingPathComponent("original-input")
    let bytes = Data((#"{"text":"apostrophe ' dollar $ backslash \\"}"# + "\n\n").utf8)
    let original = "/bin/cat > " + ClaudeSetup.shellQuote(originalInput.path) + "; printf 'ORIG:'; /usr/bin/wc -c < " + ClaudeSetup.shellQuote(originalInput.path) + "; exit 3"
    let originalJSON = String(decoding: try JSONSerialization.data(withJSONObject: original, options: [.fragmentsAllowed]), as: UTF8.self)
    expectEqual(try ClaudeSetup.decodeOriginalCommand(jsonString: originalJSON), original)
    for malformed in ["echo hi", "{}", "true", "123", "\"unterminated", "\"\\u0000\""] {
        expectEqual((try? ClaudeSetup.decodeOriginalCommand(jsonString: malformed)) == nil, true)
    }
    for shell in ClaudeSetup.Shell.allCases {
        for delay in ["", "/bin/sleep 1\n"] {
            try ("#!/bin/sh\n" + delay + "/bin/cat > " + ClaudeSetup.shellQuote(bridgeInput.path) + "\nexit 7\n").write(to: fake, atomically: true, encoding: .utf8)
            _ = chmod(fake.path, 0o700)
            let script = try ClaudeSetup.wrapperScript(executable: fake.path, originalCommandJSON: originalJSON, shell: shell)
            let wrapper = root.appendingPathComponent("wrapper.sh")
            try script.write(to: wrapper, atomically: true, encoding: .utf8)
            let result = try runClaudeTestProcess("/bin/sh", [wrapper.path], input: bytes)
            expectEqual(result.0, 3)
            expectEqual(String(decoding: result.1, as: UTF8.self).replacingOccurrences(of: " ", with: ""), "ORIG:\(bytes.count)\n")
            expectEqual(result.2, Data())
            expectEqual(try Data(contentsOf: bridgeInput), bytes)
            expectEqual(try Data(contentsOf: originalInput), bytes)
            _ = chmod(fake.path, 0o600)
            let unavailable = try runClaudeTestProcess("/bin/sh", [wrapper.path], input: bytes)
            expectEqual(unavailable.0, 3); expectEqual(unavailable.1, result.1); expectEqual(unavailable.2, Data())
        }
    }
    // JSON special escapes round-trip without manual unescaping, including newlines and Unicode.
    let specialCommand = "printf '%s\\n' \"quote \\\" \\\\ $HOME\"\n# 中文\nexit 3"
    let encodedCommand = String(decoding: try JSONSerialization.data(withJSONObject: specialCommand, options: [.fragmentsAllowed]), as: UTF8.self)
    expectEqual(try ClaudeSetup.decodeOriginalCommand(jsonString: encodedCommand), specialCommand)
    expectEqual(try ClaudeSetup.wrapperScript(executable: fake.path, originalCommandJSON: encodedCommand, shell: .bash).contains(ClaudeSetup.shellQuote(specialCommand)), true)
    let specialWrapper = root.appendingPathComponent("escaped-wrapper.sh")
    try ClaudeSetup.wrapperScript(executable: fake.path, originalCommandJSON: encodedCommand, shell: .bash).write(to: specialWrapper, atomically: true, encoding: .utf8)
    let directEscaped = try runClaudeTestProcess("/bin/bash", ["-c", specialCommand], input: bytes)
    let wrappedEscaped = try runClaudeTestProcess("/bin/sh", [specialWrapper.path], input: bytes)
    expectEqual(wrappedEscaped.0, directEscaped.0); expectEqual(wrappedEscaped.1, directEscaped.1); expectEqual(wrappedEscaped.2, directEscaped.2)
    var statusLine: [String: Any] = ["type": "command", "command": specialCommand, "padding": 2, "refreshInterval": 7, "hideVimModeIndicator": true]
    let backup = try JSONSerialization.data(withJSONObject: statusLine, options: [.sortedKeys])
    statusLine["command"] = try JSONSerialization.jsonObject(with: Data(ClaudeSetup.wrapperCommandJSONString.utf8), options: [.fragmentsAllowed]) as! String
    expectEqual(statusLine["padding"] as? Int, 2); expectEqual(statusLine["refreshInterval"] as? Int, 7); expectEqual(statusLine["hideVimModeIndicator"] as? Bool, true)
    statusLine["command"] = specialCommand
    expectEqual(try JSONSerialization.data(withJSONObject: statusLine, options: [.sortedKeys]), backup)
    expectEqual(ClaudeSetup.isTranslocated(path: "/private/var/folders/x/AppTranslocation/y/CodexHUD"), true)
    expectEqual(ClaudeSetup.isTranslocated(path: "/Applications/Codex HUD.app/Contents/MacOS/CodexHUD"), false)
    expectEqual(ClaudeSetup.pathWarning("/private/tmp/example") != nil, true)
    expectEqual(ClaudeSetup.pathWarning("/Volumes/Disk/example") != nil, true)
    expectEqual(ClaudeSetup.pathWarning("/Applications/Codex HUD.app/Contents/MacOS/CodexHUD"), nil)
}
