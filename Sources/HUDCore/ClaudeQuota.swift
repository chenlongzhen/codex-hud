import Foundation
import CoreFoundation

public enum ClaudeReadFailure: String, Error, Codable {
    case untrustedLocation, notRegularFile, permissions, tooLarge, malformed, unsupportedSchema, clockSkew, ioError
    public var text: String {
        switch self {
        case .untrustedLocation: return "目录不可信"
        case .notRegularFile: return "不是普通文件"
        case .permissions: return "权限异常"
        case .tooLarge: return "文件过大"
        case .malformed: return "格式异常"
        case .unsupportedSchema: return "版本不支持"
        case .clockSkew: return "时间异常"
        case .ioError: return "读取错误"
        }
    }
}
public struct ClaudeWindow: Codable, Equatable {
    public var usedPercentage: Double
    public var resetsAt: Int64
    public var changedAt: Int64
    public init(usedPercentage: Double, resetsAt: Int64, changedAt: Int64) {
        self.usedPercentage = usedPercentage; self.resetsAt = resetsAt; self.changedAt = changedAt
    }
    private enum CodingKeys: String, CodingKey { case usedPercentage, resetsAt, changedAt }
}
public struct ClaudeSnapshot: Codable, Equatable {
    public var schema = 1
    public var bridgeSeenAt: Int64
    public var fiveHour: ClaudeWindow?
    public var sevenDay: ClaudeWindow?
    public init(bridgeSeenAt: Int64, fiveHour: ClaudeWindow? = nil, sevenDay: ClaudeWindow? = nil) {
        self.bridgeSeenAt = bridgeSeenAt; self.fiveHour = fiveHour; self.sevenDay = sevenDay
    }
    private enum CodingKeys: String, CodingKey { case schema, bridgeSeenAt, fiveHour, sevenDay }
    public static let minTime: Int64 = 1_600_000_000
    public static let maxTime: Int64 = 4_102_444_800 // 2100; bounded arithmetic, not arbitrary Int64 dates.
    public static func validTime(_ value: Int64) -> Bool { (minTime...maxTime).contains(value) }
    public func validate(now: Int64) throws {
        guard schema == 1 else { throw ClaudeReadFailure.unsupportedSchema }
        guard Self.validTime(now), Self.validTime(bridgeSeenAt), bridgeSeenAt <= now + 300 else { throw ClaudeReadFailure.clockSkew }
        for (window, horizon) in [(fiveHour, Int64(18_600)), (sevenDay, Int64(608_400))] {
            guard let window else { continue }
            guard window.usedPercentage.isFinite, (0...100).contains(window.usedPercentage) else { throw ClaudeReadFailure.malformed }
            guard Self.validTime(window.changedAt), window.changedAt <= bridgeSeenAt,
                  Self.validTime(window.resetsAt), window.resetsAt <= bridgeSeenAt + horizon else { throw ClaudeReadFailure.clockSkew }
        }
    }
    public func encoded(now: Int64) throws -> Data {
        try validate(now: now)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data, now: Int64) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any],
              Set(root.keys).isSubset(of: ["schema", "bridgeSeenAt", "fiveHour", "sevenDay"]),
              let schema = integer(root["schema"]), let seen = integer(root["bridgeSeenAt"]) else { throw ClaudeReadFailure.malformed }
        guard schema == 1 else { throw ClaudeReadFailure.unsupportedSchema }
        func window(_ key: String) throws -> ClaudeWindow? {
            guard let value = root[key] else { return nil }
            guard let item = value as? [String: Any], Set(item.keys) == ["usedPercentage", "resetsAt", "changedAt"],
                  let used = number(item["usedPercentage"]), let reset = integer(item["resetsAt"]), let changed = integer(item["changedAt"]) else { throw ClaudeReadFailure.malformed }
            return ClaudeWindow(usedPercentage: used, resetsAt: reset, changedAt: changed)
        }
        let snapshot = try Self(bridgeSeenAt: seen, fiveHour: window("fiveHour"), sevenDay: window("sevenDay"))
        try snapshot.validate(now: now); return snapshot
    }
}
private func number(_ object: Any?) -> Double? {
    guard let n = object as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
    return n.doubleValue
}
private func integer(_ object: Any?) -> Int64? {
    guard let n = object as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: n.objCType)) else { return nil }
    return Int64(n.stringValue) // Checked textual conversion also rejects UInt64 overflow.
}
public struct ClaudeStatuslineInput {
    public var fiveHour: ClaudeWindow?
    public var sevenDay: ClaudeWindow?
    public static func parse(_ data: Data, now: Int64) -> Self? {
        guard ClaudeSnapshot.validTime(now), data.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else { return nil }
        let limits = root["rate_limits"] as? [String: Any] ?? [:]
        func window(_ key: String, horizon: Int64) -> ClaudeWindow? {
            guard let item = limits[key] as? [String: Any], let used = number(item["used_percentage"]), (0...100).contains(used),
                  let reset = number(item["resets_at"]), reset >= Double(ClaudeSnapshot.minTime), reset <= Double(ClaudeSnapshot.maxTime) else { return nil }
            let seconds = Int64(reset.rounded(.down))
            guard seconds > now, seconds <= now + horizon else { return nil }
            return ClaudeWindow(usedPercentage: used, resetsAt: seconds, changedAt: now)
        }
        return Self(fiveHour: window("five_hour", horizon: 18_600), sevenDay: window("seven_day", horizon: 608_400))
    }
    public var stdout: String {
        [("5h", fiveHour), ("W", sevenDay)].compactMap { label, window in
            window.map { "\(label) \(ClaudePresentation.remainingText(100 - $0.usedPercentage))" }
        }.joined(separator: " · ") + "\n"
    }
}
public enum ClaudeSnapshotMerge {
    public static func merge(existing: ClaudeSnapshot?, input: ClaudeStatuslineInput, now: Int64) throws -> ClaudeSnapshot? {
        guard ClaudeSnapshot.validTime(now) else { throw ClaudeReadFailure.clockSkew }
        // Preserve future observations on clock rollback, even within the reader's 300s tolerance.
        if let existing {
            try existing.validate(now: now)
            if existing.bridgeSeenAt > now { throw ClaudeReadFailure.clockSkew }
        }
        func merged(_ old: ClaudeWindow?, _ new: ClaudeWindow?) -> ClaudeWindow? {
            guard var new else { return old } // Expired evidence is retained until replaced or cleared.
            if let old, old.usedPercentage == new.usedPercentage, old.resetsAt == new.resetsAt { new.changedAt = old.changedAt }
            else { new.changedAt = now }
            return new
        }
        let result = ClaudeSnapshot(bridgeSeenAt: now, fiveHour: merged(existing?.fiveHour, input.fiveHour), sevenDay: merged(existing?.sevenDay, input.sevenDay))
        try result.validate(now: now)
        if let existing, existing.fiveHour == result.fiveHour, existing.sevenDay == result.sevenDay, now - existing.bridgeSeenAt < 30 { return nil }
        return result
    }
}
public enum ClaudeFileResult: Equatable {
    case absent, valid(ClaudeSnapshot), failed(ClaudeReadFailure)
    public var snapshot: ClaudeSnapshot? { if case .valid(let value) = self { return value }; return nil }
    public var kind: String { switch self { case .absent: return "absent"; case .valid: return "valid"; case .failed(let failure): return failure.rawValue } }
}
public enum ClaudeWindowState: String {
    case missing, passed, stale, observed
    public static func evaluate(window: ClaudeWindow?, now: Int64, staleAfter: Int64 = 900) -> Self {
        guard let window, ClaudeSnapshot.validTime(now), ClaudeSnapshot.validTime(window.changedAt), ClaudeSnapshot.validTime(window.resetsAt), window.usedPercentage.isFinite, (0...100).contains(window.usedPercentage) else { return .missing }
        if now >= window.resetsAt { return .passed }
        if now > window.changedAt, now - window.changedAt >= staleAfter { return .stale }
        return .observed
    }
}
public enum ClaudeOverall: String { case disabled, noSnapshot, failed, waiting, observed, stale }
public struct ClaudePresentation {
    public let file: ClaudeFileResult
    public let now: Int64
    public let enabled: Bool
    public init(file: ClaudeFileResult?, now: Int64, enabled: Bool = true) {
        self.enabled = enabled
        self.now = ClaudeSnapshot.validTime(now) ? now : ClaudeSnapshot.minTime
        if !ClaudeSnapshot.validTime(now) { self.file = .failed(.clockSkew) }
        else if let snapshot = file?.snapshot {
            do { try snapshot.validate(now: now); self.file = .valid(snapshot) }
            catch let failure as ClaudeReadFailure { self.file = .failed(failure) }
            catch { self.file = .failed(.malformed) }
        } else { self.file = file ?? .absent }
    }
    public var fiveHour: ClaudeWindow? { enabled ? file.snapshot?.fiveHour : nil }
    public var sevenDay: ClaudeWindow? { enabled ? file.snapshot?.sevenDay : nil }
    public var fiveHourState: ClaudeWindowState { .evaluate(window: fiveHour, now: now) }
    public var sevenDayState: ClaudeWindowState { .evaluate(window: sevenDay, now: now) }
    public var overall: ClaudeOverall {
        if !enabled { return .disabled }
        switch file {
        case .absent: return .noSnapshot
        case .failed: return .failed
        case .valid:
            if fiveHourState == .missing && sevenDayState == .missing { return .waiting }
            return fiveHourState == .observed || sevenDayState == .observed ? .observed : .stale
        }
    }
    public var exhausted: Bool { [.observed, .stale].contains(fiveHourState) && fiveHour?.usedPercentage == 100 }
    public static func remainingText(_ value: Double) -> String {
        guard value.isFinite, (0...100).contains(value) else { return "—" }
        return value > 0 && value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }
    public func remaining(_ window: ClaudeWindow?) -> String {
        guard enabled, let window, [.observed, .stale].contains(ClaudeWindowState.evaluate(window: window, now: now)) else { return "—" }
        return Self.remainingText(100 - window.usedPercentage)
    }
    public var tabText: String { remaining(sevenDay) }
    public var marker: String { exhausted ? "exhausted" : (overall == .failed || sevenDayState == .stale ? "warning" : "none") }
    public var bridgeAge: Int64? { file.snapshot.map { max(0, now - $0.bridgeSeenAt) } }
    public var message: String {
        switch overall {
        case .disabled: return "已关闭"
        case .noSnapshot: return "尚未收到桥接数据"
        case .failed: if case .failed(let failure) = file { return "读取失败 · \(failure.text)" }; return "读取失败"
        case .waiting: return "等待数据 · 桥接 \((bridgeAge ?? 0) / 60) 分钟前运行过，尚未收到额度字段"
        case .observed, .stale: return "本地观测 · 桥接 \((bridgeAge ?? 0) / 60) 分钟前"
        }
    }
    public var statusText: String {
        switch overall {
        case .observed: return "已收到观测 · " + message
        case .stale: return "数据过旧 · " + message
        default: return message
        }
    }
    public func stateText(_ window: ClaudeWindow?) -> String {
        switch ClaudeWindowState.evaluate(window: window, now: now) {
        case .missing: return "未提供"
        case .passed: return "已到重置点 · 待同步"
        case .stale: return "旧 · \(max(0, now - (window?.changedAt ?? now)) / 60) 分钟未变化"
        case .observed: return "本地观测"
        }
    }
    public var menu: String { enabled ? "C W \(tabText)\(sevenDayState == .stale ? " 旧" : "")\(exhausted ? " 5h!" : "")" : "" }
    public var tooltip: String { enabled ? "Claude 5h \(remaining(fiveHour)) · \(stateText(fiveHour))\(exhausted ? " · 观测为已用尽" : "")；Weekly \(tabText) · \(stateText(sevenDay))；\(message)" : "" }
    public var fixture: [String: Any] {
        func item(_ window: ClaudeWindow?) -> [String: Any] { ["state": ClaudeWindowState.evaluate(window: window, now: now).rawValue, "remaining": remaining(window)] }
        return ["file": file.kind, "overall": overall.rawValue, "fiveHour": item(fiveHour), "sevenDay": item(sevenDay), "tabClaudeText": tabText, "tabClaudeMarker": marker, "fiveHourExhaustedHint": exhausted, "menuSummaryClaude": menu, "tooltipClaude": tooltip]
    }
}
public enum ClaudeDiagnostics {
    public static func fields(file: ClaudeFileResult?, now: Int64, enabled: Bool = true) -> [String: Any] {
        let p = ClaudePresentation(file: file, now: now, enabled: enabled)
        return ["claudeFile": p.file.kind, "claudeOverall": p.overall.rawValue, "claudeFiveHourState": p.fiveHourState.rawValue, "claudeSevenDayState": p.sevenDayState.rawValue, "claudeBridgeSeenAgeSeconds": p.bridgeAge.map { $0 as Any } ?? NSNull()]
    }
}
