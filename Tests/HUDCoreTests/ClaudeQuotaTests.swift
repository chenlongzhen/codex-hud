import Foundation
import HUDCore

let claudeTestNow: Int64 = 1_800_000_000
func claudeInput(_ text: String, now: Int64 = claudeTestNow) -> ClaudeStatuslineInput? { ClaudeStatuslineInput.parse(Data(text.utf8), now: now) }
func sampleClaudeInput(now: Int64 = claudeTestNow, five: Double = 42, week: Double = 23) -> ClaudeStatuslineInput {
    claudeInput("{\"cwd\":\"s-secret\",\"session_id\":\"s-secret\",\"workspace\":{},\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(five),\"resets_at\":\(claudeTestNow + 3600)},\"seven_day\":{\"used_percentage\":\(week),\"resets_at\":\(claudeTestNow + 86400)}}}", now: now)!
}
func testClaudeQuotaContracts() throws {
    let now = claudeTestNow
    let input = sampleClaudeInput()
    var snapshot = try ClaudeSnapshotMerge.merge(existing: nil, input: input, now: now)!
    expectEqual(input.stdout, "5h 58% · W 77%\n")
    for minute in 1...16 {
        snapshot = try ClaudeSnapshotMerge.merge(existing: snapshot, input: input, now: now + Int64(minute * 60))!
        expectEqual(snapshot.fiveHour?.changedAt, now)
    }
    expectEqual(ClaudeWindowState.evaluate(window: snapshot.fiveHour, now: now + 960), .stale)
    expectEqual(ClaudeWindowState.evaluate(window: snapshot.fiveHour, now: now + 900), .stale)
    expectEqual(ClaudeWindowState.evaluate(window: snapshot.fiveHour, now: now + 899), .observed)
    snapshot = try ClaudeSnapshotMerge.merge(existing: snapshot, input: sampleClaudeInput(five: 43), now: now + 1000)!
    expectEqual(snapshot.fiveHour?.changedAt, now + 1000)
    expectEqual(snapshot.sevenDay?.changedAt, now)
    expectEqual(try ClaudeSnapshotMerge.merge(existing: snapshot, input: sampleClaudeInput(five: 43), now: now + 1029), nil)
    expectEqual(try ClaudeSnapshotMerge.merge(existing: snapshot, input: sampleClaudeInput(five: 43), now: now + 1030)?.bridgeSeenAt, now + 1030)
    let passed = try ClaudeSnapshotMerge.merge(existing: snapshot, input: claudeInput("{}")!, now: now + 3600)!
    expectEqual(passed.fiveHour, snapshot.fiveHour)
    expectEqual(ClaudeWindowState.evaluate(window: passed.fiveHour, now: now + 3600), .passed)
    expectEqual(ClaudeWindowState.evaluate(window: passed.fiveHour, now: now + 3601), .passed)
    expectEqual(ClaudePresentation(file: .valid(passed), now: now + 3601).remaining(passed.fiveHour), "—")
    for rollback in [Int64(120), 301] {
        do { _ = try ClaudeSnapshotMerge.merge(existing: snapshot, input: input, now: snapshot.bridgeSeenAt - rollback); expectEqual("accepted rollback", "rejected rollback") }
        catch { expectEqual(error as? ClaudeReadFailure, .clockSkew) }
    }
    let encoded = try snapshot.encoded(now: now + 1000)
    expectEqual(try ClaudeSnapshot.decode(encoded, now: now + 1000), snapshot)
    let floatTime = Data("{\"schema\":1,\"bridgeSeenAt\":1800000000.0}".utf8)
    expectEqual((try? ClaudeSnapshot.decode(floatTime, now: now)) == nil, true)
    for extreme in [Int64.min, Int64.max] {
        do { _ = try ClaudeSnapshot.decode(Data("{\"schema\":1,\"bridgeSeenAt\":\(extreme)}".utf8), now: now); expectEqual("accepted extreme", "rejected") }
        catch { expectEqual(error as? ClaudeReadFailure, .clockSkew) }
    }
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    expectEqual(Set(object.keys), ["schema", "bridgeSeenAt", "fiveHour", "sevenDay"])
    expectEqual(Set((object["fiveHour"] as! [String: Any]).keys), ["usedPercentage", "resetsAt", "changedAt"])
    expectEqual(String(decoding: encoded, as: UTF8.self).contains("secret"), false)
    for field in ["bridgeSeenAt", "changedAt", "resetsAt"] {
        var bad = object
        if field == "bridgeSeenAt" { bad[field] = Int64.max }
        else { var item = bad["fiveHour"] as! [String: Any]; item[field] = Int64.max; bad["fiveHour"] = item }
        expectEqual((try? ClaudeSnapshot.decode(JSONSerialization.data(withJSONObject: bad), now: now + 1000)) == nil, true)
    }
    for malformed in ["[]", "null", "1", "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":NaN}}}", String(repeating: " ", count: 262145) + "{}"] { expectEqual(claudeInput(malformed) == nil, true) }
    for invalid in ["\"42\"", "true", "null", "101", "-1"] {
        let value = claudeInput("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(invalid),\"resets_at\":\(now + 3600)},\"seven_day\":{\"used_percentage\":23,\"resets_at\":\(now + 86400)}}}")!
        expectEqual(value.fiveHour, nil); expectEqual(value.sevenDay?.usedPercentage, 23)
    }
    for reset in ["true", "\"1800003600\"", "-1", "9223372036854775807", "1800018601", "1800000000"] {
        expectEqual(claudeInput("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":42,\"resets_at\":\(reset)}}}")!.fiveHour, nil)
    }
    expectEqual(claudeInput("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":42}}}")!.fiveHour, nil)
    expectEqual(claudeInput("{\"rate_limits\":false}")!.fiveHour, nil)
    expectEqual(ClaudePresentation(file: .valid(ClaudeSnapshot(bridgeSeenAt: now)), now: now).overall, .waiting)
    expectEqual(ClaudePresentation(file: .failed(.malformed), now: now).overall, .failed)
    expectEqual(ClaudePresentation(file: .failed(.malformed), now: now).tabText, "—")
    expectEqual(ClaudePresentation(file: .absent, now: now).overall, .noSnapshot)
    expectEqual(ClaudePresentation(file: .valid(snapshot), now: now + 1000, enabled: false).tooltip, "")
    for used in [0.0, 99.49, 99.5, 99.6, 100] {
        let sample = try ClaudeSnapshotMerge.merge(existing: nil, input: sampleClaudeInput(five: used), now: now)!
        let p = ClaudePresentation(file: .valid(sample), now: now)
        expectEqual(p.exhausted, used == 100)
        expectEqual(p.tabText, "77%")
        if used > 99 && used < 100 { expectEqual(p.remaining(p.fiveHour), "<1%") }
    }
    let replay = try ClaudeSnapshotMerge.merge(existing: snapshot, input: sampleClaudeInput(week: 80), now: now + 1100)!
    expectEqual(replay.sevenDay?.usedPercentage, 80)
    expectEqual(replay.sevenDay?.changedAt, now + 1100)
    let diag = ClaudeDiagnostics.fields(file: .valid(snapshot), now: now + 1000)
    expectEqual(Set(diag.keys), ["claudeFile", "claudeOverall", "claudeFiveHourState", "claudeSevenDayState", "claudeBridgeSeenAgeSeconds"])
    for stamp in [Int64.min, Int64.max] {
        expectEqual(ClaudeStatuslineInput.parse(Data("{}".utf8), now: stamp) == nil, true)
        expectEqual((try? snapshot.encoded(now: stamp)) == nil, true)
        expectEqual(ClaudePresentation(file: .valid(snapshot), now: stamp).overall, .failed)
        expectEqual(ClaudeWindowState.evaluate(window: ClaudeWindow(usedPercentage: 1, resetsAt: now + 3600, changedAt: stamp), now: now), .missing)
        let badOld = ClaudeSnapshot(bridgeSeenAt: stamp)
        expectEqual((try? ClaudeSnapshotMerge.merge(existing: badOld, input: input, now: now)) == nil, true)
    }
    var invalid = snapshot; invalid.fiveHour?.resetsAt = now - 1
    expectEqual(try ClaudeSnapshot.decode(invalid.encoded(now: now + 1000), now: now + 1000), invalid) // Expiry evidence is legal.
    invalid.fiveHour?.resetsAt = 0
    expectEqual((try? invalid.encoded(now: now + 1000)) == nil, true)
    var changed = object; var item = changed["fiveHour"] as! [String: Any]; item["changedAt"] = now + 1001; changed["fiveHour"] = item
    expectEqual((try? ClaudeSnapshot.decode(JSONSerialization.data(withJSONObject: changed), now: now + 1000)) == nil, true)
    expectEqual(HUDLayout.detailHeight(available: 1000, chrome: 200), 274)
    expectEqual(HUDLayout.detailHeight(available: 210, chrome: 200), 10)
    expectEqual(HUDLayout.detailHeight(available: 100, chrome: 200), 0)
    expectEqual(HUDLayout.detailHeight(available: 450, chrome: 200), 250)
}
