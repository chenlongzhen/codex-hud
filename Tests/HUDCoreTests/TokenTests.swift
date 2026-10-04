import Foundation
import HUDCore
func testTokenSnapshotsCountOnlyDeltasAndDoNotAddSubsetsTwice() {
    var ledger = TokenLedger()
    let first = TokenTotals(input: 100, cachedInput: 60, output: 20, reasoning: 10)
    let second = TokenTotals(input: 150, cachedInput: 90, output: 30, reasoning: 15)
    let a = ledger.consume(cumulative: first, last: first)
    let duplicate = ledger.consume(cumulative: first, last: first)
    let b = ledger.consume(cumulative: second, last: TokenTotals(input: 50, cachedInput: 30, output: 10, reasoning: 5))
    expectEqual((a + duplicate + b).total, 180)
    expectEqual((a + duplicate + b).cachedInput, 90)
    expectEqual((a + duplicate + b).reasoning, 15)
}
