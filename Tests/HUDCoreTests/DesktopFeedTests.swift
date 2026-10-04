import Foundation
import HUDCore
func testDesktopSnapshotWaitingTransitionAndMissingRevisionInvalidateCounts() {
    var feed = DesktopFeed()
    let now = Date()
    func event(_ change: [String: Any]) -> [String: Any] {
        ["method": "thread-stream-state-changed", "version": 11, "sourceClientId": "desktop", "params": ["hostId": "local", "conversationId": "task", "change": change]]
    }
    feed.ingest(event(["type": "snapshot", "revision": 7, "conversationState": ["title": "示例任务", "threadRuntimeStatus": ["type": "active", "activeFlags": []]]]), at: now)
    expectEqual(feed.tasks(at: now).filter { $0.status.isRunning }.count, 1)
    feed.ingest(event(["type": "patches", "baseRevision": 7, "revision": 8, "patches": [["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "active", "activeFlags": ["waitingOnApproval"]]]]]), at: now)
    expectEqual(feed.tasks(at: now).filter { $0.status.isRunning }.count, 0)
    expectEqual(feed.tasks(at: now).filter { $0.status.waitingOnApproval }.count, 1)
    feed.ingest(event(["type": "patches", "baseRevision": 9, "revision": 10, "patches": []]), at: now)
    expectEqual(feed.hasInvalidEntries(at: now), true)
    expectEqual(feed.tasks(at: now).count, 0)
    feed.ingest(event(["type": "snapshot", "revision": 11, "conversationState": ["threadRuntimeStatus": ["type": "active"]]]), at: now)
    expectEqual(feed.hasInvalidEntries(at: now), true)
    expectEqual(feed.tasks(at: now).count, 0)
    feed.ingest(event(["type": "snapshot", "revision": 12, "conversationState": ["agentNickname": "Worker", "threadRuntimeStatus": ["type": "active", "activeFlags": []]]]), at: now)
    expectEqual(feed.ids.contains("task"), true)
    expectEqual(feed.tasks(at: now).count, 0)
}
