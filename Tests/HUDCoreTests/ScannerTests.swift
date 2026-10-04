import Foundation
import HUDCore

func testScannerDayBoundaryPartialAppendCopiesAndForks() async throws {
    let manager = FileManager.default
    let home = manager.temporaryDirectory.appendingPathComponent("CodexHUD-check-" + UUID().uuidString)
    let root = home.appendingPathComponent("sessions")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: home) }
    let formatter = ISO8601DateFormatter()
    func date(_ text: String) -> Date { formatter.date(from: text)! }
    func line(_ object: [String: Any]) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); bytes.append(10); return bytes
    }
    func metadata(_ id: String, _ timestamp: String) throws -> Data {
        try line(["timestamp": timestamp, "type": "session_meta", "payload": ["id": id, "timestamp": timestamp]])
    }
    func event(_ timestamp: String, _ input: Int, _ output: Int, _ lastInput: Int, _ lastOutput: Int) throws -> Data {
        try line(["timestamp": timestamp, "type": "event_msg", "payload": ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": input, "output_tokens": output],
            "last_token_usage": ["input_tokens": lastInput, "output_tokens": lastOutput]]]])
    }
    let meta = try metadata("parent", "2026-10-01T00:00:00Z")
    let beforeWeek = try event("2026-09-30T23:59:59Z", 50, 5, 50, 5)
    let early = try event("2026-10-02T10:00:00Z", 100, 10, 50, 5)
    let beforeDay = try event("2026-10-03T15:59:59Z", 200, 20, 100, 10)
    let midnight = try event("2026-10-03T16:00:00Z", 250, 25, 50, 5)
    let repeated = try event("2026-10-03T16:00:01Z", 250, 25, 50, 5)
    let appended = try event("2026-10-04T00:00:00Z", 350, 35, 100, 10)
    var content = meta + beforeWeek + early + beforeDay + midnight + repeated
    let file = root.appendingPathComponent("parent.jsonl")
    try (content + appended.prefix(appended.count / 2)).write(to: file)
    let scanner = TokenScanner(home: home)
    let now = date("2026-10-04T01:00:00Z"), week = date("2026-10-01T00:00:00Z")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let initial = try await scanner.scan(now: now, weekStart: week, calendar: calendar)
    expectEqual(initial.today.total, 55)
    expectEqual(initial.weekly?.total, 220)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
    try handle.write(contentsOf: appended.suffix(from: appended.count / 2)); try handle.close()
    let incremental = try await scanner.scan(now: now, weekStart: week, calendar: calendar)
    expectEqual(incremental.today.total, 165)
    expectEqual(incremental.weekly?.total, 330)
    content += appended
    try content.write(to: root.appendingPathComponent("copy.jsonl"))
    let forkMeta = try metadata("child", "2026-10-04T00:15:00Z")
    let forkContent = forkMeta + early + beforeDay + midnight + appended + (try event("2026-10-04T00:30:00Z", 400, 40, 50, 5))
    try forkContent.write(to: root.appendingPathComponent("fork.jsonl"))
    let forked = try await scanner.scan(now: now, weekStart: week, calendar: calendar)
    expectEqual(forked.today.total, 220)
    expectEqual(forked.weekly?.total, 385)
    let repeatedScan = try await scanner.scan(now: now, weekStart: week, calendar: calendar)
    expectEqual(repeatedScan.today, forked.today)
    expectEqual(repeatedScan.issues.isEmpty, true)
    let noCycle = try await scanner.scan(now: now, weekStart: nil, calendar: calendar)
    expectEqual(noCycle.weekly == nil, true)
    try manager.removeItem(at: root.appendingPathComponent("copy.jsonl"))
    try manager.removeItem(at: root.appendingPathComponent("fork.jsonl"))
    let truncated = meta + (try event("2026-10-04T00:45:00Z", 10, 1, 10, 1))
    try truncated.write(to: file)
    let replaced = try await scanner.scan(now: now, weekStart: week, calendar: calendar)
    expectEqual(replaced.today.total, 11)
    expectEqual(replaced.weekly?.total, 11)
}

func testCounterRestartAndFutureEvents() {
    var ledger = TokenLedger()
    expectEqual(ledger.consume(cumulative: TokenTotals(input: 1000, output: 100), last: TokenTotals(input: 10, output: 1)).total, 11)
    expectEqual(ledger.consume(cumulative: TokenTotals(input: 50, output: 10), last: TokenTotals(input: 20, output: 3)).total, 23)
    let now = Date(timeIntervalSince1970: 1791075600)
    let events = [TokenEvent(date: now, key: "one", usage: TokenTotals(input: 100, output: 20)), TokenEvent(date: now.addingTimeInterval(1), key: "future", usage: TokenTotals(input: 999))]
    let report = TokenReport.aggregate(events, now: now, calendar: .current, weekStart: now.addingTimeInterval(-604800))
    expectEqual(report.today.total, 120)
    expectEqual(report.weekly?.total, 120)
}

func testReadOnlyRPCRejectsControlMethods() async {
    expectEqual(AppServer.findExecutable(override: "/codex-hud-missing-executable") == nil, true)
    let client = AppServer()
    for method in ["turn/start", "turn/interrupt", "thread/resume", "account/rateLimitResetCredit/consume"] {
        do { _ = try await client.request(method); expectEqual(true, false) }
        catch { expectEqual(error.localizedDescription.contains("禁止调用写操作"), true) }
    }
}
