import Foundation
#if DEBUG
@testable import HUDCore
#else
import HUDCore
#endif
var failures = 0
var checks = 0
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #file, line: Int = #line) {
    checks += 1
    if actual != expected { failures += 1; print("FAIL \(URL(fileURLWithPath: file).lastPathComponent):\(line): \(actual) != \(expected)"); fflush(stdout) }
}
#if DEBUG
ClaudeProbe.executePTYChildIfRequested(CommandLine.arguments)
if runProbeFixtureIfNeeded() { exit(0) }
if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--export-wrapper" {
    let shell = ClaudeSetup.Shell(rawValue: CommandLine.arguments[5])!
    let text = try ClaudeSetup.wrapperScript(executable: CommandLine.arguments[3], originalCommandJSON: CommandLine.arguments[4], shell: shell)
    try text.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--test-lock-worker" {
    let now = Int64(Date().timeIntervalSince1970)
    let data = Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":42,\"resets_at\":\(now + 3600)}}}".utf8)
    let input = ClaudeStatuslineInput.parse(data, now: now)!
    _ = ClaudeSnapshotFile.writeForTesting(input: input, directory: CommandLine.arguments[2], now: now, beforeReplace: {
        print("LOCKED"); fflush(stdout)
        while true { pause() }
    })
    exit(1)
}
#endif
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
try testClaudeQuotaContracts()
claudeUsageTests()
testClaudeProxyConfiguration()
#if DEBUG
try testClaudeSnapshotFiles()
try testClaudeProbeExecutionAndSchedule()
#endif
try testClaudeSetupTextAndWrappers()
if failures > 0 { exit(1) }
print("PASS: \(checks) behavior checks")
