import Foundation

public enum ClaudeSetup {
    public enum Shell: String, CaseIterable { case sh = "/bin/sh", bash = "/bin/bash", zsh = "/bin/zsh" }
    public enum SetupError: Error { case commandMustBeJSONString }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func bridgeCommand(executable: String) -> String { shellQuote(executable) + " --claude-statusline-bridge" }
    public static func statusLineJSON(command: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": command]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    public static func decodeOriginalCommand(jsonString: String) throws -> String {
        guard let data = jsonString.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), let command = object as? String, !command.utf8.contains(0) else { throw SetupError.commandMustBeJSONString }
        return command
    }
    /// Pure text only. Never reads settings, saves a script, executes or tests the pasted command.
    public static func wrapperScript(executable: String, originalCommandJSON: String, shell: Shell) throws -> String {
        let original = try decodeOriginalCommand(jsonString: originalCommandJSON)
        return """
        #!/bin/sh
        # Codex HUD: generated text; review and save manually. Keep your original settings backup.
        # Input collection waits for EOF and is NOT covered by the bridge's 2s budget.
        # Shell variables cannot represent NUL; no input size bound here; no stdin is written to disk.
        # Group SIGTERM cancels the group. Wrapper-only signals need not kill descendants.
        trap 'exit 143' TERM
        trap 'exit 130' INT
        trap 'exit 129' HUP
        input=$(/bin/cat; printf x)
        input=${input%x}
        printf '%s' "$input" | \(shellQuote(executable)) --claude-statusline-bridge --silent >/dev/null 2>&1
        printf '%s' "$input" | \(shell.rawValue) -c \(shellQuote(original))
        """ + "\n"
    }
    public static var wrapperCommand: String { "/bin/sh \"$HOME/.claude/codex-hud-statusline.sh\"" }
    public static var wrapperCommandJSONString: String {
        let data = try! JSONSerialization.data(withJSONObject: wrapperCommand, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    public static func isTranslocated(path: String) -> Bool { path.contains("/AppTranslocation/") }
    public static func pathWarning(_ path: String) -> String? {
        if isTranslocated(path: path) { return "请先把 Codex HUD.app 移到‘应用程序’文件夹后重新打开" }
        if ["/private/var/folders/", "/var/folders/", "/tmp/", "/private/tmp/", "/Volumes/"].contains(where: path.hasPrefix) { return "当前路径可能是临时位置；移动或删除 app 后需重新复制配置" }
        return nil
    }
}
