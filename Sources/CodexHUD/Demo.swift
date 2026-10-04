import Foundation
import HUDCore

/// Synthetic documentation data. This path never starts a connection or scans sessions.
@MainActor
func loadDemoData(into store: HUDStore) throws {
    let now = Date()
    let response: [String: Any] = [
        "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 36, "windowDurationMins": 10080, "resetsAt": now.addingTimeInterval(3 * 86400).timeIntervalSince1970]],
        "rateLimitResetCredits": ["availableCount": 3, "credits": [18, 216, 336].enumerated().map { index, hours in
            ["id": "demo-card-\(index)", "status": "available", "expiresAt": now.addingTimeInterval(Double(hours) * 3600).timeIntervalSince1970] as [String: Any]
        }]
    ]
    store.quota = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONSerialization.data(withJSONObject: response))
    store.now = now; store.serverConnected = true
    store.quotaUpdatedAt = now.addingTimeInterval(-4); store.cardDetailsUpdatedAt = now
    store.tasksAvailable = true; store.tasksUpdatedAt = now
    store.tasksSource = "演示数据 · Demo data"
    store.settings.codexHome = "~/.codex"
    store.tasks = [
        HUDTask(id: "00000000-0000-4000-8000-000000000001", title: "Build a desktop utility", status: ThreadStatus(type: "active", activeFlags: [])),
        HUDTask(id: "00000000-0000-4000-8000-000000000002", title: "Review a pull request", status: ThreadStatus(type: "active", activeFlags: [])),
        HUDTask(id: "00000000-0000-4000-8000-000000000003", title: "Choose a documentation layout", status: ThreadStatus(type: "active", activeFlags: ["waitingOnUserInput"]))
    ]
    store.tokenReport = TokenReport.aggregate([
        TokenEvent(date: now, key: "demo-today", usage: TokenTotals(input: 12_000_000, cachedInput: 9_600_000, output: 300_000, reasoning: 90_000)),
        TokenEvent(date: Calendar.current.startOfDay(for: now).addingTimeInterval(-3600), key: "demo-earlier", usage: TokenTotals(input: 36_000_000, cachedInput: 30_000_000, output: 300_000, reasoning: 110_000))
    ], now: now, calendar: .current, weekStart: store.weekly?.cycleStart)
}
