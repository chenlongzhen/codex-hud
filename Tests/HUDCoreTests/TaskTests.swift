import Foundation
import HUDCore
func testWaitingTasksAreNeverCountedAsRunning() {
    let statuses = [ThreadStatus(type: "active", activeFlags: []), ThreadStatus(type: "active", activeFlags: ["waitingOnApproval"]), ThreadStatus(type: "active", activeFlags: ["waitingOnUserInput"]), ThreadStatus(type: "active", activeFlags: ["waitingOnApproval", "waitingOnUserInput"]), ThreadStatus(type: "notLoaded")]
    expectEqual(statuses.filter(\.isRunning).count, 1)
    expectEqual(statuses.filter(\.isWaiting).count, 3)
    expectEqual(statuses[1].waitingOnApproval, true)
    expectEqual(statuses[2].waitingOnInput, true)
    expectEqual(ThreadStatus(type: "active").isRunning, false)
    expectEqual(ThreadStatus(type: "active", activeFlags: ["futureUnknownFlag"]).isRunning, false)
}
