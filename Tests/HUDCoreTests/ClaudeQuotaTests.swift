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
    expectEqual(snapshot.fiveHour?.confirmedAt, nil)
    expectEqual(ClaudeWindowState.evaluate(window: snapshot.fiveHour, now: now + 960), .stale)
    expectEqual(ClaudeWindowState.evaluate(window: snapshot.fiveHour, now: now + 901), .stale)
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
        do { _ = try ClaudeSnapshotMerge.merge(existing: snapshot, input: input, now: snapshot.bridgeSeenAt! - rollback); expectEqual("accepted rollback", "rejected rollback") }
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
    expectEqual(object["schema"] as? Int, 2)
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
    expectEqual(Set(diag.keys), ["claudeFile", "claudeOverall", "claudeFiveHourState", "claudeSevenDayState", "claudeBridgeSeenAgeSeconds", "claudeProbedAgeSeconds"])
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
    try testClaudeProbeMerges()
}

private func testClaudeProbeMerges() throws {
    let now = claudeTestNow
    let precise = ClaudeWindow(usedPercentage: 8.4, resetsAt: now + 3601, changedAt: now)
    let initial = ClaudeSnapshot(bridgeSeenAt: now, fiveHour: precise, sevenDay: ClaudeWindow(usedPercentage: 23.1, resetsAt: now + 86400, changedAt: now))
    let probe = ClaudeProbeWindow(usedPercentage: 8, resetsAt: now + 3600)
    let refreshed = try ClaudeSnapshotMerge.merge(existing: initial, probe: (probe, nil), now: now + 960)
    expectEqual(refreshed.schema, 2)
    expectEqual(refreshed.bridgeSeenAt, now)
    expectEqual(refreshed.probedAt, now + 960)
    expectEqual(refreshed.fiveHour?.changedAt, now)
    expectEqual(refreshed.fiveHour?.confirmedAt, now + 960)
    expectEqual(refreshed.fiveHour?.usedPercentage, precise.usedPercentage)
    expectEqual(refreshed.fiveHour?.resetsAt, precise.resetsAt)
    expectEqual(refreshed.sevenDay, initial.sevenDay)
    expectEqual(ClaudeWindowState.evaluate(window: refreshed.fiveHour, now: now + 960), .observed)
    expectEqual(ClaudePresentation(file: .valid(refreshed), now: now + 960).message, "主动查询 · 0 分钟前")
    expectEqual(ClaudePresentation(file: .valid(refreshed), now: now + 1860).stateText(refreshed.fiveHour), "旧 · 15 分钟未确认")

    let probeOnly = try ClaudeSnapshotMerge.merge(existing: nil, probe: (probe, nil), now: now)
    expectEqual(probeOnly.bridgeSeenAt, nil)
    expectEqual(probeOnly.probedAt, now)
    let encoded = try probeOnly.encoded(now: now)
    expectEqual(try ClaudeSnapshot.decode(encoded, now: now), probeOnly)
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    expectEqual(Set(object.keys), ["schema", "probedAt", "fiveHour"])
    let diagnostics = ClaudeDiagnostics.fields(file: .valid(probeOnly), now: now)
    expectEqual(diagnostics["claudeBridgeSeenAgeSeconds"] is NSNull, true)
    expectEqual(diagnostics["claudeProbedAgeSeconds"] as? Int64, 0)
    let waiting = ClaudePresentation(file: .valid(ClaudeSnapshot(bridgeSeenAt: nil, probedAt: now)), now: now)
    expectEqual(waiting.message, "等待数据 · 主动查询 0 分钟前运行过，尚未解析到额度")

    for seconds in [120, 121, 5400, 5401] {
        let hourOnly = seconds > 121
        let proposed = ClaudeProbeWindow(usedPercentage: 8, resetsAt: precise.resetsAt + Int64(seconds), hourOnly: hourOnly)
        let result = try ClaudeSnapshotMerge.merge(existing: initial, probe: (proposed, nil), now: now + 60)
        let same = seconds == 120 || seconds == 5400
        expectEqual(result.fiveHour?.changedAt, same ? now : now + 60)
        expectEqual(result.fiveHour?.resetsAt, same ? precise.resetsAt : proposed.resetsAt)
    }
    let roundedOld = ClaudeSnapshot(bridgeSeenAt: now, fiveHour: ClaudeWindow(usedPercentage: 8.6, resetsAt: now + 3600, changedAt: now))
    let roundedSame = try ClaudeSnapshotMerge.merge(existing: roundedOld, probe: (ClaudeProbeWindow(usedPercentage: 9, resetsAt: now + 3600), nil), now: now + 60)
    expectEqual(roundedSame.fiveHour?.changedAt, now) // M2 compares round(old), not the raw decimal.
    expectEqual(roundedSame.fiveHour?.usedPercentage, 8.6)
    let roundedDifferent = try ClaudeSnapshotMerge.merge(existing: roundedOld, probe: (probe, nil), now: now + 60)
    expectEqual(roundedDifferent.fiveHour?.changedAt, now + 60)

    for used in [8.0, 9.0] {
        let unresolved = ClaudeProbeWindow(usedPercentage: used, resetsAt: nil)
        let result = try ClaudeSnapshotMerge.merge(existing: initial, probe: (unresolved, nil), now: now + 60)
        expectEqual(result.fiveHour?.confirmedAt, used == 8 ? now + 60 : nil)
        expectEqual(result.fiveHour?.usedPercentage, precise.usedPercentage)
    }
    let expired = try ClaudeSnapshotMerge.merge(existing: initial, probe: (ClaudeProbeWindow(usedPercentage: 8, resetsAt: nil), nil), now: now + 3602)
    expectEqual(expired.fiveHour, precise)
    let empty = try ClaudeSnapshotMerge.merge(existing: nil, probe: (ClaudeProbeWindow(usedPercentage: 8, resetsAt: nil), nil), now: now)
    expectEqual(empty.fiveHour, nil)

    let bridgeInput = claudeInput("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":8.4,\"resets_at\":\(now + 3601)}}}")!
    let bridged = try ClaudeSnapshotMerge.merge(existing: probeOnly, input: bridgeInput, now: now + 60)!
    expectEqual(bridged.probedAt, now)
    expectEqual(bridged.fiveHour?.changedAt, now)
    expectEqual(bridged.fiveHour?.confirmedAt, now) // Replay cannot advance active confirmation.
    expectEqual(bridged.fiveHour?.usedPercentage, 8.4)
    expectEqual(bridged.fiveHour?.resetsAt, now + 3601)
    expectEqual(ClaudePresentation(file: .valid(bridged), now: now + 60).probeIsSource, false)
    let tie = ClaudePresentation(file: .valid(ClaudeSnapshot(bridgeSeenAt: now, probedAt: now)), now: now)
    expectEqual(tie.probeIsSource, true)

    let oldSchema = Data("{\"schema\":1,\"bridgeSeenAt\":\(now),\"fiveHour\":{\"usedPercentage\":8.4,\"resetsAt\":\(now + 3601),\"changedAt\":\(now)}}".utf8)
    let legacy = try ClaudeSnapshot.decode(oldSchema, now: now)
    expectEqual(legacy.schema, 1)
    expectEqual(legacy.fiveHour?.confirmedAt, nil)
    expectEqual(try ClaudeSnapshot.decode(legacy.encoded(now: now), now: now).schema, 2)
    expectEqual(try ClaudeSnapshotMerge.merge(existing: legacy, probe: (probe, nil), now: now + 60).schema, 2)
    let oldBridge = ClaudeSnapshot(bridgeSeenAt: now - 3 * 86400)
    let newWeek = ClaudeProbeWindow(usedPercentage: 23, resetsAt: now + 6 * 86400)
    let latestBounds = try ClaudeSnapshotMerge.merge(existing: oldBridge, probe: (nil, newWeek), now: now)
    expectEqual(try ClaudeSnapshot.decode(latestBounds.encoded(now: now), now: now), latestBounds)

    for invalid in [
        "{\"schema\":2}",
        "{\"schema\":1,\"probedAt\":\(now)}",
        "{\"schema\":1,\"bridgeSeenAt\":\(now),\"probedAt\":\(now)}",
        "{\"schema\":2,\"probedAt\":true}",
        "{\"schema\":2,\"probedAt\":null}",
        "{\"schema\":2,\"probedAt\":\(now),\"unknown\":0}",
        "{\"schema\":2,\"probedAt\":18446744073709551615}"
    ] { expectEqual((try? ClaudeSnapshot.decode(Data(invalid.utf8), now: now)) == nil, true) }
    var badWindow = precise; badWindow.confirmedAt = now - 1
    expectEqual((try? ClaudeSnapshot(bridgeSeenAt: now, fiveHour: badWindow).encoded(now: now)) == nil, true)
    badWindow.confirmedAt = now + 1
    expectEqual((try? ClaudeSnapshot(bridgeSeenAt: now, fiveHour: badWindow).encoded(now: now)) == nil, true)
    for invalid in [Int64.min, Int64.max] {
        let badProbe = ClaudeProbeWindow(usedPercentage: 8, resetsAt: invalid)
        expectEqual((try? ClaudeSnapshotMerge.merge(existing: initial, probe: (badProbe, nil), now: now)) == nil, true)
        expectEqual((try? ClaudeSnapshotMerge.merge(existing: initial, probe: (probe, nil), now: invalid)) == nil, true)
    }
    for invalid in [-1.0, 101, Double.nan, Double.infinity] {
        expectEqual((try? ClaudeSnapshotMerge.merge(existing: initial, probe: (ClaudeProbeWindow(usedPercentage: invalid, resetsAt: nil), nil), now: now)) == nil, true)
    }
    for rollback in [Int64(1), 120, 301] {
        expectEqual((try? ClaudeSnapshotMerge.merge(existing: probeOnly, probe: (probe, nil), now: now - rollback)) == nil, true)
        expectEqual((try? ClaudeSnapshotMerge.merge(existing: probeOnly, input: bridgeInput, now: now - rollback)) == nil, true)
    }

    func usable(_ window: ClaudeProbeWindow?, old: ClaudeSnapshot? = nil, at stamp: Int64? = nil) -> ClaudeProbeResult {
        ClaudeSnapshotMerge.usableProbe(ClaudeProbeResult(status: .success, fiveHour: window), existing: old, now: stamp ?? now)
    }
    expectEqual(usable(probe).status, .success)
    expectEqual(usable(nil).status, .parseFailed)
    let unresolved = ClaudeProbeWindow(usedPercentage: 8, resetsAt: nil)
    expectEqual(usable(unresolved).status, .parseFailed)
    expectEqual(usable(unresolved, old: initial).fiveHour?.resetsAt, precise.resetsAt)
    expectEqual(usable(ClaudeProbeWindow(usedPercentage: 9, resetsAt: nil), old: initial).status, .parseFailed)
    expectEqual(usable(unresolved, old: initial, at: precise.resetsAt).status, .parseFailed)
    expectEqual(usable(unresolved, old: initial, at: now - 1).status, .parseFailed)
    for delta in [Int64(-60), -59, 0, ClaudeSnapshot.fiveHourHorizon, ClaudeSnapshot.fiveHourHorizon + 1] {
        let result = usable(ClaudeProbeWindow(usedPercentage: 8, resetsAt: now + delta))
        expectEqual(result.status, delta > -60 && delta <= ClaudeSnapshot.fiveHourHorizon ? .success : .parseFailed)
        if result.status == .success, delta <= 0 {
            let merged = try ClaudeSnapshotMerge.merge(existing: nil, probe: (result.fiveHour, nil), now: now)
            expectEqual(ClaudeWindowState.evaluate(window: merged.fiveHour, now: now), .passed)
            expectEqual(ClaudePresentation(file: .valid(merged), now: now).remaining(merged.fiveHour), "—")
        }
    }
    for extreme in [Int64.min, Int64.max] {
        expectEqual(usable(ClaudeProbeWindow(usedPercentage: 8, resetsAt: extreme)).status, .parseFailed)
        expectEqual(usable(probe, at: extreme).status, .parseFailed)
    }
    let partial = ClaudeSnapshotMerge.usableProbe(ClaudeProbeResult(status: .success, fiveHour: unresolved, sevenDay: newWeek), existing: nil, now: now)
    expectEqual(partial.status, .success); expectEqual(partial.fiveHour, nil); expectEqual(partial.sevenDay, newWeek)
    let failure = ClaudeProbeResult(status: .rateLimited, retryAfter: now + 60)
    expectEqual(ClaudeSnapshotMerge.usableProbe(failure, existing: nil, now: now), failure)
}
