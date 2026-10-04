import Foundation
import HUDCore

@MainActor
func runDiagnostics() async -> Int32 {
    let store = HUDStore()
    let started = Date()
    store.start()
    while Date().timeIntervalSince(started) < 45 {
        store.pollForDiagnostics()
        if store.quotaUpdatedAt != nil && store.weeklyTokens != nil && store.tasksAvailable && store.cards?.detailsComplete == true { break }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var result: [String: Any] = [
        "capturedAt": formatter.string(from: Date()),
        "quotaAvailable": store.quotaUpdatedAt != nil,
        "quotaStale": store.quotaStale,
        "tasksAvailable": store.tasksAvailable,
        // Do not export upstream error text; a custom server could include private data.
        "tasksSource": store.settings.socketPath != nil ? "shared-app-server" : (store.settings.desktopFeedEnabled ? "desktop-ipc-v11" : "disabled"),
        "tokenAvailable": store.tokenReport != nil,
        "secondsToSnapshot": Date().timeIntervalSince(started)
    ]
    result["weeklyRemainingPercent"] = store.weekly?.remainingPercent
    result["weeklyReset"] = store.weekly?.resetDate.map(formatter.string(from:))
    result["weeklyCycleStart"] = store.tokenReport?.weekStart.map(formatter.string(from:))
    result["resetCardCount"] = store.cards?.availableCount
    result["resetCardDetailsComplete"] = store.cards?.detailsComplete
    result["resetCards"] = store.cards?.sorted.map { ["expiresAt": $0.expiry.map(formatter.string(from:)) ?? "unknown", "severity": $0.severity(at: Date()).rawValue] as [String: Any] }
    result["running"] = store.tasksAvailable ? store.running.count : nil
    result["waitingOnUserInput"] = store.tasksAvailable ? store.waiting.filter { $0.status.waitingOnInput }.count : nil
    result["waitingOnApproval"] = store.tasksAvailable ? store.waiting.filter { $0.status.waitingOnApproval }.count : nil
    result["waitingTotal"] = store.tasksAvailable ? store.waiting.count : nil
    result["taskStatusTypes"] = store.tasks.map { $0.status.type }
    if let report = store.tokenReport {
        result["tokensAsOf"] = formatter.string(from: report.updatedAt)
        result["todayTokens"] = report.today.total
        result["weeklyTokens"] = store.weeklyTokens?.total
        result["todayBreakdown"] = ["input": report.today.input, "cachedInput": report.today.cachedInput, "output": report.today.output, "reasoning": report.today.reasoning]
        result["sessionFilesScanned"] = report.scannedFiles
        result["tokenIssues"] = report.issues
    }
    result["error"] = store.issue
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    let passed = store.quotaUpdatedAt != nil && store.tokenReport?.issues.isEmpty == true && store.weeklyTokens != nil && store.tasksAvailable && !store.quotaStale && store.cards?.detailsComplete == true
    store.stop()
    try? await Task.sleep(nanoseconds: 200_000_000)
    return passed ? 0 : 2
}
