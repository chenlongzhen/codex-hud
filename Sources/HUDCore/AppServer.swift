import Foundation

public enum HUDError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// A read-only JSON-RPC client. The allowlist is the entire outbound authority of the HUD.
public final class AppServer: @unchecked Sendable {
    private static let allowed: Set<String> = ["initialize", "account/rateLimits/read", "thread/loaded/list", "thread/read"]
    private let queue = DispatchQueue(label: "CodexHUD.app-server")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    public var onNotification: (@Sendable (String) -> Void)?

    public init() {}

    public static func findExecutable(override: String? = nil) -> String? {
        if let override { return FileManager.default.isExecutableFile(atPath: override) ? override : nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            home + "/Applications/Codex.app/Contents/Resources/codex",
            home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func start(executable: String, codexHome: URL, socket: String? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.stopLocked()
                let child = Process(), stdin = Pipe(), stdout = Pipe()
                child.executableURL = URL(fileURLWithPath: executable)
                child.arguments = socket.map { ["app-server", "proxy", "--sock", $0] }
                    ?? ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"]
                var environment = ProcessInfo.processInfo.environment
                environment["CODEX_HOME"] = codexHome.path
                child.environment = environment
                child.standardInput = stdin
                child.standardOutput = stdout
                // App-server stderr can contain account or conversation data; never persist it.
                child.standardError = FileHandle.nullDevice
                self.process = child
                self.input = stdin.fileHandleForWriting
                self.output = stdout.fileHandleForReading
                stdout.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
                    let data = handle.availableData
                    self?.queue.async { [weak self, weak child] in
                        guard let self, let child, self.process === child else { return }
                        if data.isEmpty { self.failPending("app-server 已断开"); handle.readabilityHandler = nil }
                        else { self.receive(data) }
                    }
                }
                child.terminationHandler = { [weak self] child in
                    self?.queue.async { [weak self] in
                        guard let self, self.process === child else { return }
                        self.failPending("app-server 已退出")
                        self.onNotification?("offline")
                    }
                }
                do { try child.run(); continuation.resume() }
                catch { self.stopLocked(); continuation.resume(throwing: error) }
            }
        }
        _ = try await request("initialize", params: [
            "clientInfo": ["name": "codex_hud", "title": "Codex HUD", "version": "1.0.0"],
            "capabilities": ["experimentalApi": true]
        ])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.write(["method": "initialized"]); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> Data {
        guard Self.allowed.contains(method) else { throw HUDError.message("HUD 禁止调用写操作：\(method)") }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.process?.isRunning == true else { continuation.resume(throwing: HUDError.message("app-server 未连接")); return }
                self.nextID += 1
                let id = self.nextID
                self.pending[id] = continuation
                do { try self.write(["id": id, "method": method, "params": params]) }
                catch { self.pending.removeValue(forKey: id)?.resume(throwing: error); return }
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.pending.removeValue(forKey: id)?.resume(throwing: HUDError.message("\(method) 读取超时"))
                }
            }
        }
    }

    public func stop() { queue.async { self.stopLocked() } }

    private func stopLocked() {
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? input?.close(); try? output?.close()
        process = nil; input = nil; output = nil; buffer.removeAll()
        failPending("app-server 连接已关闭")
    }

    private func failPending(_ message: String) {
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.resume(throwing: HUDError.message(message)) }
    }

    private func write(_ message: [String: Any]) throws {
        guard let input else { throw HUDError.message("app-server 未连接") }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        // Check before parsing, including responses that already contain a newline.
        guard buffer.count <= 32 * 1024 * 1024 else {
            failPending("app-server 响应超出支持范围"); stopLocked(); onNotification?("offline"); return
        }
        while let end = buffer.range(of: Data([10]))?.lowerBound {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, let request = pending.removeValue(forKey: id) {
                if let error = object["error"] as? [String: Any] {
                    request.resume(throwing: HUDError.message(error["message"] as? String ?? "app-server 读取失败"))
                } else if let result = object["result"], let data = try? JSONSerialization.data(withJSONObject: result) {
                    request.resume(returning: data)
                } else { request.resume(throwing: HUDError.message("app-server 响应格式不支持")) }
            } else if let method = object["method"] as? String { onNotification?(method) }
        }
    }
}
