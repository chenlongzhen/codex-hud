import Foundation

public struct QuotaSnapshot: Decodable {
    public let accountId: String?
    public let rateLimits: RateLimitBucket?
    public let rateLimitsByLimitId: [String: RateLimitBucket]?
    public let rateLimitResetCredits: ResetCredits?
    public var weekly: RateWindow? {
        // A weekly window can be primary. Reserve/model-specific buckets are not the Codex quota.
        let bucket = rateLimitsByLimitId?["codex"] ?? rateLimits
        guard bucket?.limitId == nil || bucket?.limitId == "codex" else { return nil }
        return [bucket?.primary, bucket?.secondary].compactMap { $0 }
            .first { $0.windowDurationMins == 7 * 24 * 60 }
    }
}
public struct RateLimitBucket: Decodable {
    public let limitId: String?
    public let primary: RateWindow?
    public let secondary: RateWindow?
}
public struct RateWindow: Decodable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?
    public var remainingPercent: Double? { usedPercent.map { min(100, max(0, 100 - $0)) } }
    public var resetDate: Date? { validEpoch(resetsAt) }
    public var cycleStart: Date? {
        guard let resetDate, let minutes = windowDurationMins else { return nil }
        return resetDate.addingTimeInterval(-Double(minutes) * 60)
    }
}
public struct ResetCredits: Decodable {
    public let availableCount: Int?
    public let credits: [ResetCredit]?
    public var sorted: [ResetCredit] {
        (credits ?? []).filter { $0.status == "available" }
            .sorted { ($0.expiry ?? .distantFuture) < ($1.expiry ?? .distantFuture) }
    }
    public var detailsComplete: Bool { credits != nil && sorted.count == availableCount && sorted.allSatisfy { $0.expiry != nil } }
}
public enum ExpirySeverity: Int, Comparable {
    case normal, warning, urgent, expired
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
public struct ResetCredit: Decodable, Identifiable {
    public let id: String
    public let status: String
    public let expiresAt: Double?
    public let title: String?
    public var expiry: Date? { validEpoch(expiresAt) }
    public func severity(at now: Date) -> ExpirySeverity {
        guard status == "available", let expiry else { return .normal }
        let remaining = expiry.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining <= 24 * 3600 { return .urgent }
        if remaining <= 3 * 24 * 3600 { return .warning }
        return .normal
    }
}

private func validEpoch(_ value: Double?) -> Date? {
    // Reject malformed timestamps before converting countdowns to integer display values.
    guard let value, value.isFinite, (0...253_402_300_799).contains(value) else { return nil }
    return Date(timeIntervalSince1970: value)
}
