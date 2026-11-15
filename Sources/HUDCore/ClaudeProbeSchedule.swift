import Foundation

/// Pure scheduler. Uses monotonic seconds so wall-clock rollback cannot cause a retry storm.
public struct ClaudeProbeSchedule {
    public private(set) var nextAttempt: Double?
    public private(set) var lastAttempt: Double?
    public private(set) var running = false
    public private(set) var paused = false
    public private(set) var enabled = false
    public private(set) var failures = 0
    public private(set) var blocked = false
    public var interval: Double = 900
    public init() {}
    public mutating func configure(enabled: Bool, interval: Int, uptime: Double) {
        self.enabled = enabled; self.interval = Double([900, 1800, 3600].contains(interval) ? interval : 900)
        failures = 0; blocked = false
        nextAttempt = enabled ? uptime + 10 : nil
    }
    public var canRequestManually: Bool { enabled && !paused && !running }
    public func manualAllowed(uptime: Double) -> Bool {
        canRequestManually && lastAttempt.map { uptime - $0 >= 60 } ?? canRequestManually
    }
    public mutating func sleep() { paused = true }
    public mutating func wake(uptime: Double) { paused = false; if enabled && !blocked { nextAttempt = max(nextAttempt ?? 0, uptime + 30) } }
    public mutating func begin(uptime: Double, now: Int64, snapshot: ClaudeSnapshot?, manual: Bool = false, lowPower: Bool = false) -> Bool {
        guard enabled, !paused, !running else { return false }
        if manual { guard manualAllowed(uptime: uptime) else { return false } }
        else {
            guard !blocked, let nextAttempt, uptime >= nextAttempt else { return false }
            // Passive input can be replayed cached data. It must never move the independent
            // active deadline, even when bridgeSeenAt/confirmedAt looks recent (F1).
        }
        running = true; lastAttempt = uptime; nextAttempt = nil; blocked = false
        return true
    }
    public mutating func finish(result: ClaudeProbeResult, uptime: Double, now: Int64, lowPower: Bool = false) {
        running = false
        guard enabled else { return }
        if result.status.stopsAutomaticRetry { blocked = true; nextAttempt = nil; return }
        if result.status == .cancelled { nextAttempt = uptime + 30; return }
        if result.status == .busy { nextAttempt = uptime + 120; return }
        if result.status == .success { failures = 0 }
        else { failures = min(6, failures + 1) }
        let cadence = min(14_400, interval * pow(2, Double(failures)) * (lowPower ? 2 : 1))
        let retry = result.retryAfter.flatMap { ClaudeSnapshot.validTime($0) && $0 > now ? Double($0 - now) : nil } ?? 0
        nextAttempt = uptime + max(cadence, retry)
    }
    public mutating func invalidate() { running = false; nextAttempt = nil }
}
