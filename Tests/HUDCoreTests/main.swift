import Foundation
import HUDCore
var failures = 0
var checks = 0
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #file, line: Int = #line) {
    checks += 1
    if actual != expected { failures += 1; print("FAIL \(URL(fileURLWithPath: file).lastPathComponent):\(line): \(actual) != \(expected)"); fflush(stdout) }
}
try QuotaTests().testWeeklyMayBePrimaryAndNeverSubstitutesFiveHourOrReserveBucket()
testWaitingTasksAreNeverCountedAsRunning()
testTokenSnapshotsCountOnlyDeltasAndDoNotAddSubsetsTwice()
try testExpiryWarningsIncludeExactBoundariesAndMissingDetailsStayUnknown()
testDesktopSnapshotWaitingTransitionAndMissingRevisionInvalidateCounts()
try await testScannerDayBoundaryPartialAppendCopiesAndForks()
testCounterRestartAndFutureEvents()
await testReadOnlyRPCRejectsControlMethods()
try await testUnresponsiveAndDisconnectedServerFailClearly()
try testWindowPreferencesPersistAndOldSettingsKeepTheirConnection()
testDockingUsesCurrentScreenAndRestoresReadableFrame()
try testExtremeTimestampsAreNotPresentedAsValidDates()
testTokenOverflowIsReportedWithoutCrashing()
try await testOversizedSessionLineIsSkippedAndScanningRecovers()
try await testOversizedCompleteRPCResponseFailsBeforeDecoding()
if failures > 0 { exit(1) }
print("PASS: \(checks) behavior checks")
