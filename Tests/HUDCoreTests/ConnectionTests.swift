import Foundation
import HUDCore

func testUnresponsiveAndDisconnectedServerFailClearly() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodexHUD-connection-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("server")
    let script = """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '{"id":1,"result":{}}\\n' ;;
        *rateLimits*) exit 0 ;;
      esac
    done
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = AppServer()
    defer { client.stop() }
    try await client.start(executable: executable.path, codexHome: folder)
    do {
        _ = try await client.request("thread/read", params: ["threadId": "example"], timeout: 0.05)
        expectEqual(true, false)
    } catch { expectEqual(error.localizedDescription.contains("超时"), true) }
    do {
        _ = try await client.request("account/rateLimits/read", timeout: 1)
        expectEqual(true, false)
    } catch { expectEqual(error.localizedDescription.contains("断开") || error.localizedDescription.contains("退出"), true) }
}
