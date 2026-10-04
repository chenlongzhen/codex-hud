import Foundation
import HUDCore

func testOversizedSessionLineIsSkippedAndScanningRecovers() async throws {
    let manager = FileManager.default
    let home = manager.temporaryDirectory.appendingPathComponent("CodexHUD-bounds-" + UUID().uuidString)
    let sessions = home.appendingPathComponent("sessions")
    try manager.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: home) }
    let file = sessions.appendingPathComponent("oversized.jsonl")
    try Data(repeating: 120, count: 17 * 1024 * 1024).write(to: file)
    let now = Date(), scanner = TokenScanner(home: home)
    let first = try await scanner.scan(now: now, weekStart: nil)
    expectEqual(first.issues.isEmpty, false)
    let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
    let event: [String: Any] = ["timestamp": timestamp, "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 20]]]]
    var append = Data([10]); append += try JSONSerialization.data(withJSONObject: event); append.append(10)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.close()
    let recovered = try await scanner.scan(now: now, weekStart: nil)
    expectEqual(recovered.today.total, 120)
    expectEqual(recovered.issues.count, 1)
}

func testOversizedCompleteRPCResponseFailsBeforeDecoding() async throws {
    let manager = FileManager.default
    let folder = manager.temporaryDirectory.appendingPathComponent("CodexHUD-response-" + UUID().uuidString)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("server")
    let script = """
    #!/usr/bin/python3
    import json,sys
    for line in sys.stdin:
        request=json.loads(line)
        if request.get('method') == 'initialize':
            print(json.dumps({'id':request['id'],'result':{}}),flush=True)
        elif request.get('method') == 'account/rateLimits/read':
            print(json.dumps({'id':request['id'],'result':{'padding':'x'*(32*1024*1024)}}),flush=True)
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = AppServer(); defer { client.stop() }
    try await client.start(executable: executable.path, codexHome: folder)
    do {
        _ = try await client.request("account/rateLimits/read", timeout: 10)
        expectEqual(true, false)
    } catch { expectEqual(error.localizedDescription.contains("超出"), true) }
}

func testExtremeTimestampsAreNotPresentedAsValidDates() throws {
    let quota = try JSONDecoder().decode(QuotaSnapshot.self, from: Data("""
    {"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1e100}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"sample","status":"available","expiresAt":1e100}]}}
    """.utf8))
    expectEqual(quota.weekly?.resetDate == nil, true)
    expectEqual(quota.rateLimitResetCredits?.sorted.first?.expiry == nil, true)
}

func testTokenOverflowIsReportedWithoutCrashing() {
    let now = Date()
    let events = [TokenEvent(date: now, key: "oversized", usage: TokenTotals(input: Int64.max, output: 1))]
    let report = TokenReport.aggregate(events, now: now, calendar: .current, weekStart: now.addingTimeInterval(-60))
    expectEqual(report.issues.isEmpty, false)
    expectEqual(report.today.total, Int64.max)
}
