import Foundation
import HUDCore
struct QuotaTests {
    func testWeeklyMayBePrimaryAndNeverSubstitutesFiveHourOrReserveBucket() throws {
        let data = Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":77,"windowDurationMins":10080,"resetsAt":1791612146},"secondary":null},"base_model_inference":{"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1791697321}}}}"#.utf8)
        let quota = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
        expectEqual(quota.weekly?.remainingPercent, 23)
        expectEqual(quota.weekly?.cycleStart?.timeIntervalSince1970, 1791007346)
        let short = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}}}"#.utf8))
        expectEqual(short.weekly == nil, true)
        let reserve = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(#"{"rateLimits":{"limitId":"base_model_inference","primary":{"usedPercent":0,"windowDurationMins":10080}}}"#.utf8))
        expectEqual(reserve.weekly == nil, true)
    }
}
