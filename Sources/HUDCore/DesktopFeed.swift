import Foundation

/// Reduces Desktop v11 snapshot/patch broadcasts, retaining only status metadata.
public struct DesktopFeed {
    private struct Entry {
        var title: String
        var status: [String: Any]
        var revision: Int
        var owner: String
        var receivedAt: Date
        var valid: Bool
    }
    private var entries: [String: Entry] = [:]
    private var excluded = Set<String>()
    public init() {}
    public mutating func ingest(_ message: [String: Any], at date: Date) {
        guard let method = message["method"] as? String, let params = message["params"] as? [String: Any] else { return }
        if method == "client-status-changed", params["status"] as? String == "disconnected", let owner = params["clientId"] as? String {
            for id in entries.keys where entries[id]?.owner == owner { entries[id]?.valid = false }
            return
        }
        guard method == "thread-stream-state-changed", params["hostId"] as? String == "local",
              let id = params["conversationId"] as? String, let change = params["change"] as? [String: Any] else { return }
        guard message["version"] as? Int == 11 else { entries[id]?.valid = false; return }
        let owner = message["sourceClientId"] as? String ?? ""
        guard let revision = change["revision"] as? Int else { entries[id]?.valid = false; return }
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            // Task totals represent user-owned chats, not their subagents/side conversations.
            guard state["sideConversation"] as? Bool != true,
                  (state["agentNickname"] as? String) == nil else {
                entries.removeValue(forKey: id); excluded.insert(id); return
            }
            excluded.remove(id)
            let status = state["threadRuntimeStatus"] as? [String: Any] ?? [:]
            entries[id] = Entry(title: state["title"] as? String ?? String(id.prefix(8)), status: status,
                                revision: revision, owner: owner, receivedAt: date, valid: decodeStatus(status) != nil)
        } else if change["type"] as? String == "patches", var entry = entries[id] {
            guard entry.valid, entry.owner == owner, change["baseRevision"] as? Int == entry.revision,
                  let patches = change["patches"] as? [[String: Any]] else { entries[id]?.valid = false; return }
            for patch in patches {
                guard let path = patch["path"] as? [Any], let first = path.first as? String else { continue }
                if first == "threadRuntimeStatus" {
                    if path.count == 1, let status = patch["value"] as? [String: Any] { entry.status = status }
                    else if path.count == 2, let key = path[1] as? String { entry.status[key] = patch["value"] }
                    else { entry.valid = false }
                } else if first == "title", let title = patch["value"] as? String { entry.title = title }
            }
            entry.revision = revision; entry.receivedAt = date
            entry.valid = entry.valid && decodeStatus(entry.status) != nil
            entries[id] = entry
        }
    }
    public mutating func remove(_ id: String) { entries.removeValue(forKey: id); excluded.remove(id) }
    public func owner(of id: String) -> String? { entries[id]?.owner }
    public mutating func confirmOwner(_ id: String, at date: Date) { if entries[id]?.valid == true { entries[id]?.receivedAt = date } }
    public mutating func invalidate(_ id: String) { entries[id]?.valid = false }
    public func needsSnapshot(_ id: String, at date: Date) -> Bool {
        if excluded.contains(id) { return false }
        guard let entry = entries[id] else { return true }
        return !entry.valid || date.timeIntervalSince(entry.receivedAt) > 45
    }
    public var ids: Set<String> { Set(entries.keys).union(excluded) }
    public func tasks(at now: Date) -> [HUDTask] {
        entries.compactMap { id, entry in
            guard entry.valid, now.timeIntervalSince(entry.receivedAt) <= 45,
                  let status = decodeStatus(entry.status) else { return nil }
            return HUDTask(id: id, title: entry.title, status: status, updatedAt: entry.receivedAt)
        }.sorted { $0.title < $1.title }
    }
    public func hasInvalidEntries(at now: Date) -> Bool { entries.values.contains { !$0.valid || now.timeIntervalSince($0.receivedAt) > 45 } }
    private func decodeStatus(_ value: [String: Any]) -> ThreadStatus? {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let status = try? JSONDecoder().decode(ThreadStatus.self, from: data), status.isSupported else { return nil }
        return status
    }
}

/// Decode only status fields from initial snapshots, which can contain large histories.
/// Ignored history fields are never converted into Foundation object trees or retained.
enum DesktopSnapshotMetadata {
    private struct Envelope: Decodable {
        let method: String?
        let version: Int?
        let sourceClientId: String?
        let params: Params?
        struct Params: Decodable {
            let hostId: String?
            let conversationId: String?
            let change: Change?
        }
        struct Change: Decodable {
            let type: String?
            let revision: Int?
            let conversationState: State?
        }
        struct State: Decodable {
            let title: String?
            let sideConversation: Bool?
            let agentNickname: String?
            let threadRuntimeStatus: ThreadStatus?
        }
    }
    static func decode(_ data: Data) -> [String: Any]? {
        guard let event = try? JSONDecoder().decode(Envelope.self, from: data), let params = event.params,
              let change = params.change, change.type == "snapshot", let state = change.conversationState else { return nil }
        var minimal: [String: Any] = [:]
        minimal["title"] = state.title
        minimal["sideConversation"] = state.sideConversation
        minimal["agentNickname"] = state.agentNickname
        if let status = state.threadRuntimeStatus, let data = try? JSONEncoder().encode(status) {
            minimal["threadRuntimeStatus"] = try? JSONSerialization.jsonObject(with: data)
        }
        return ["method": event.method ?? "", "version": event.version ?? -1, "sourceClientId": event.sourceClientId ?? "",
                "params": ["hostId": params.hostId ?? "", "conversationId": params.conversationId ?? "",
                           "change": ["type": "snapshot", "revision": change.revision ?? -1, "conversationState": minimal]]]
    }
}
