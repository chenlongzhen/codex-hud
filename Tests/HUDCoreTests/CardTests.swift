import Foundation
import HUDCore
func testExpiryWarningsIncludeExactBoundariesAndMissingDetailsStayUnknown() throws {
    let quota = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(#"{"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"b","status":"available","expiresAt":259200,"title":"Full reset"},{"id":"a","status":"available","expiresAt":86400,"title":"Full reset"}]}}"#.utf8))
    let cards = quota.rateLimitResetCredits!
    expectEqual(cards.availableCount, 3)
    expectEqual(cards.detailsComplete, false)
    expectEqual(cards.sorted.map(\.id), ["a", "b"])
    expectEqual(cards.sorted[0].severity(at: Date(timeIntervalSince1970: 0)), .urgent)
    expectEqual(cards.sorted[1].severity(at: Date(timeIntervalSince1970: 0)), .warning)
    expectEqual(cards.sorted[1].severity(at: Date(timeIntervalSince1970: -1)), .normal)
    expectEqual(cards.sorted[0].severity(at: Date(timeIntervalSince1970: 86400)), .expired)
}
