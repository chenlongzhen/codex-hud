import Foundation
import Darwin

public struct DesktopStatus {
    public let tasks: [HUDTask]
    public let available: Bool
    public let connected: Bool
    public let message: String
    public let updatedAt: Date?
}

/// Optional fallback for Desktop's stdio-only server. Uses the observed local IPC v11 feed.
/// It can only initialize, decline discovery requests, and subscribe/unsubscribe to state.
public final class DesktopObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexHUD.desktop-state")
    private let home: URL
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var clientID: String?
    private var initializeID: String = ""
    private var candidates = Set<String>()
    private var subscribed = Set<String>()
    private var feed = DesktopFeed()
    private var lastConnect = Date.distantPast
    private var lastSubscribe = Date.distantPast
    private var lastUpdate: Date?
    private var issue = "Desktop 状态尚未连接"
    private var unsupported = false
    private var discoveryAvailable = false
    private var heartbeats: [String: (id: String, sentAt: Date)] = [:]
    public var onChange: (@Sendable () -> Void)?

    public init(home: URL) { self.home = home }
    public func refresh() {
        queue.async {
            let folder = self.home.appendingPathComponent("thread-writer-locks")
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path); self.discoveryAvailable = true }
            catch { self.discoveryAvailable = false; self.issue = "Desktop 任务索引不可读"; return }
            let locked = Set(names.compactMap { name -> String? in
                guard name.hasSuffix(".lock") else { return nil }
                let id = String(name.dropLast(5))
                return UUID(uuidString: id) == nil ? nil : id
            })
            // SQLite only discovers candidate IDs. Counts always require live runtime status.
            // Avoid requesting megabytes of completed-thread history on every launch.
            if let unfinished = try? LocalTasks.unfinished(home: self.home) {
                self.candidates = Set(unfinished.map(\.id)).intersection(locked)
            } else { self.candidates = locked }
            for id in self.subscribed.subtracting(self.candidates) {
                self.follow(id, value: false); self.feed.remove(id)
            }
            self.subscribed.formIntersection(self.candidates)
            for (request, pending) in self.heartbeats where Date().timeIntervalSince(pending.sentAt) > 8 {
                self.feed.invalidate(pending.id); self.heartbeats.removeValue(forKey: request)
                self.issue = "Desktop 状态心跳超时"
            }
            if self.descriptor < 0 { self.connect() }
            else if self.clientID == nil && Date().timeIntervalSince(self.lastConnect) > 5 { self.disconnect("Desktop 握手超时") }
            else if self.clientID != nil && Date().timeIntervalSince(self.lastSubscribe) >= 15 { self.subscribe() }
        }
    }
    public func snapshot() async -> DesktopStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                let now = Date(), tasks = self.feed.tasks(at: now)
                let ready = self.clientID != nil && self.discoveryAvailable && !self.unsupported && !self.feed.hasInvalidEntries(at: now)
                    && self.candidates.isSubset(of: self.feed.ids)
                continuation.resume(returning: DesktopStatus(tasks: tasks, available: ready, connected: self.clientID != nil,
                    message: ready ? "Desktop 本地状态 · 实验接口 v11" : self.issue,
                    updatedAt: self.lastUpdate))
            }
        }
    }
    public func stop() { queue.async { self.disconnect("Desktop 状态连接已关闭") } }

    private func connect() {
        guard Date().timeIntervalSince(lastConnect) >= 5 else { return }
        lastConnect = Date()
        let path = home.appendingPathComponent("ipc/ipc.sock").path
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            issue = "Desktop 状态接口不可用"; return
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { issue = "无法打开 Desktop 状态连接"; return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); issue = "Desktop 已离线"; return }
        // Verify the connected peer too; checking the path alone leaves a replacement race.
        var peerUID: uid_t = 0, peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            Darwin.close(fd); issue = "Desktop 状态连接身份不匹配"; return
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        descriptor = fd; buffer.removeAll(); feed = DesktopFeed(); unsupported = false
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readSocket() }
        reader.setCancelHandler { Darwin.close(fd) }
        source = reader; reader.resume()
        initializeID = UUID().uuidString
        send(["type": "request", "requestId": initializeID, "sourceClientId": "initializing-client", "version": 0,
              "method": "initialize", "params": ["clientType": "codex-hud"]])
    }

    private func disconnect(_ reason: String) {
        source?.cancel(); source = nil; descriptor = -1; clientID = nil; subscribed.removeAll()
        buffer.removeAll(); feed = DesktopFeed(); lastUpdate = nil; issue = reason
        heartbeats.removeAll()
        onChange?()
    }
    private func subscribe() {
        guard clientID != nil else { return }
        lastSubscribe = Date()
        for id in candidates.sorted() {
            if feed.needsSnapshot(id, at: Date()) { follow(id, value: true); subscribed.insert(id) }
            else if let owner = feed.owner(of: id), let clientID {
                let request = UUID().uuidString
                heartbeats[request] = (id, Date())
                send(["type": "request", "requestId": request, "sourceClientId": clientID, "version": 1,
                      "method": "thread-owner-discovery", "targetClientId": owner,
                      "params": ["hostId": "local", "conversationId": id]])
            }
        }
    }
    private func follow(_ id: String, value: Bool) {
        guard let clientID else { return }
        send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
              "sourceClientId": clientID, "params": ["conversationId": id, "hostId": "local", "following": value]])
    }
    private func send(_ object: [String: Any]) {
        guard descriptor >= 0, let json = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(json.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(json)
        let sent = frame.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, frame.count, 0) }
        if sent != frame.count { disconnect("Desktop 状态连接中断") }
    }
    private func readSocket() {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count == 0 { disconnect("Desktop 已离线"); return }
        if count < 0 { if errno != EAGAIN { disconnect("Desktop 状态读取失败") }; return }
        buffer.append(contentsOf: bytes.prefix(count))
        while buffer.count >= 4 {
            let length = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
            guard length > 0, length <= 256 * 1024 * 1024 else { disconnect("Desktop 状态帧超出支持范围"); return }
            guard buffer.count >= length + 4 else { return }
            let start = buffer.index(buffer.startIndex, offsetBy: 4)
            let end = buffer.index(start, offsetBy: length)
            autoreleasepool {
                let data = Data(buffer[start..<end]); buffer.removeSubrange(..<end)
                if buffer.isEmpty { buffer = Data() }
                if let object = DesktopSnapshotMetadata.decode(data) { receive(object) }
                else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { receive(object) }
            }
            if length > 4 * 1024 * 1024 { _ = malloc_zone_pressure_relief(nil, 0) }
        }
    }
    private func receive(_ object: [String: Any]) {
        if let request = object["requestId"] as? String, let pending = heartbeats.removeValue(forKey: request) {
            if object["resultType"] as? String == "success" {
                feed.confirmOwner(pending.id, at: Date()); lastUpdate = Date()
            } else { feed.invalidate(pending.id); issue = "Desktop 任务所有者暂不可用" }
            onChange?(); return
        }
        if object["requestId"] as? String == initializeID, let result = object["result"] as? [String: Any], let id = result["clientId"] as? String {
            clientID = id; issue = "等待 Desktop 任务状态"; subscribe(); onChange?(); return
        }
        if object["type"] as? String == "client-discovery-request", let request = object["requestId"] {
            send(["type": "client-discovery-response", "requestId": request, "response": ["canHandle": false]])
            return
        }
        if object["method"] as? String == "thread-stream-state-changed" {
            guard let params = object["params"] as? [String: Any],
                  let id = params["conversationId"] as? String, candidates.contains(id) else { return }
            if object["version"] as? Int != 11 { unsupported = true; issue = "Desktop 状态协议版本不支持" }
            else { lastUpdate = Date() }
        }
        feed.ingest(object, at: Date())
        if feed.hasInvalidEntries(at: Date()) { issue = "Desktop 状态过期，正在重新同步" }
        onChange?()
    }
}
