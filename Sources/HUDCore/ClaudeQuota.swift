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
    /// Last active /usage confirmation of this value. Passive replay is not confirmation.
    public var confirmedAt: Int64?
    public init(usedPercentage: Double, resetsAt: Int64, changedAt: Int64, confirmedAt: Int64? = nil) {
        self.usedPercentage = usedPercentage; self.resetsAt = resetsAt; self.changedAt = changedAt; self.confirmedAt = confirmedAt
    }
    private enum CodingKeys: String, CodingKey { case usedPercentage, resetsAt, changedAt, confirmedAt }
    public var freshAt: Int64 { confirmedAt ?? changedAt }
    /// Value equality that ignores when it was last confirmed (bridge throttle).
    func sameValue(_ other: ClaudeWindow?) -> Bool {
        guard let other else { return false }
        return usedPercentage == other.usedPercentage && resetsAt == other.resetsAt && changedAt == other.changedAt
    }
}
public struct ClaudeSnapshot: Codable, Equatable {
    public var schema = 2
    public var bridgeSeenAt: Int64?
    public var probedAt: Int64?
    public var fiveHour: ClaudeWindow?
    public var sevenDay: ClaudeWindow?
    public init(bridgeSeenAt: Int64?, probedAt: Int64? = nil, fiveHour: ClaudeWindow? = nil, sevenDay: ClaudeWindow? = nil, schema: Int = 2) {
        self.schema = schema; self.bridgeSeenAt = bridgeSeenAt; self.probedAt = probedAt; self.fiveHour = fiveHour; self.sevenDay = sevenDay
    }
    private enum CodingKeys: String, CodingKey { case schema, bridgeSeenAt, probedAt, fiveHour, sevenDay }
    public static let minTime: Int64 = 1_600_000_000
    public static let maxTime: Int64 = 4_102_444_800 // 2100; bounded arithmetic, not arbitrary Int64 dates.
    public static let fiveHourHorizon: Int64 = 18_600
    public static let sevenDayHorizon: Int64 = 608_400
    public static func validTime(_ value: Int64) -> Bool { (minTime...maxTime).contains(value) }
    /// Latest observation by either source; all schema-2 bounds use it.
    public var observedAt: Int64 { max(bridgeSeenAt ?? 0, probedAt ?? 0) }
    public func validate(now: Int64) throws {
        switch schema {
        case 1:
            guard bridgeSeenAt != nil, probedAt == nil, fiveHour?.confirmedAt == nil, sevenDay?.confirmedAt == nil else { throw ClaudeReadFailure.malformed }
        case 2:
            guard bridgeSeenAt != nil || probedAt != nil else { throw ClaudeReadFailure.malformed }
        default: throw ClaudeReadFailure.unsupportedSchema
        }
        guard Self.validTime(now) else { throw ClaudeReadFailure.clockSkew }
        for stamp in [bridgeSeenAt, probedAt] { if let stamp, !Self.validTime(stamp) { throw ClaudeReadFailure.clockSkew } }
        let observed = observedAt
        guard observed <= now + 300 else { throw ClaudeReadFailure.clockSkew }
        for (window, horizon) in [(fiveHour, Self.fiveHourHorizon), (sevenDay, Self.sevenDayHorizon)] {
            guard let window else { continue }
            guard window.usedPercentage.isFinite, (0...100).contains(window.usedPercentage) else { throw ClaudeReadFailure.malformed }
            guard Self.validTime(window.changedAt), window.changedAt <= observed,
                  Self.validTime(window.resetsAt), window.resetsAt <= observed + horizon else { throw ClaudeReadFailure.clockSkew }
            if let confirmed = window.confirmedAt {
                guard Self.validTime(confirmed), confirmed <= observed, window.changedAt <= confirmed else { throw ClaudeReadFailure.clockSkew }
            }
        }
    }
    public func encoded(now: Int64) throws -> Data {
        var current = self; current.schema = 2 // Writers always emit schema 2.
        try current.validate(now: now)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(current)
    }
    public static let schema1Keys: Set<String> = ["schema", "bridgeSeenAt", "fiveHour", "sevenDay"]
    public static let schema2Keys: Set<String> = ["schema", "bridgeSeenAt", "probedAt", "fiveHour", "sevenDay"]
    public static func decode(_ data: Data, now: Int64) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any],
              Set(root.keys).isSubset(of: schema2Keys), let schema = integer(root["schema"]) else { throw ClaudeReadFailure.malformed }
        guard schema == 1 || schema == 2 else { throw ClaudeReadFailure.unsupportedSchema }
        func stamp(_ key: String) throws -> Int64? {
            guard let value = root[key] else { return nil }
            guard let parsed = integer(value) else { throw ClaudeReadFailure.malformed }
            return parsed
        }
        let seen = try stamp("bridgeSeenAt"), probed = try stamp("probedAt")
        if schema == 1 { guard Set(root.keys).isSubset(of: schema1Keys), seen != nil else { throw ClaudeReadFailure.malformed } }
        let windowKeys: Set<String> = ["usedPercentage", "resetsAt", "changedAt"]
        func window(_ key: String) throws -> ClaudeWindow? {
            guard let value = root[key] else { return nil }
            guard let item = value as? [String: Any], windowKeys.isSubset(of: Set(item.keys)),
                  Set(item.keys).isSubset(of: schema == 1 ? windowKeys : windowKeys.union(["confirmedAt"])),
                  let used = number(item["usedPercentage"]), let reset = integer(item["resetsAt"]), let changed = integer(item["changedAt"]) else { throw ClaudeReadFailure.malformed }
            var confirmed: Int64?
            if let raw = item["confirmedAt"] { guard let value = integer(raw) else { throw ClaudeReadFailure.malformed }; confirmed = value }
            return ClaudeWindow(usedPercentage: used, resetsAt: reset, changedAt: changed, confirmedAt: confirmed)
        }
        let snapshot = try Self(bridgeSeenAt: seen, probedAt: probed, fiveHour: window("fiveHour"), sevenDay: window("sevenDay"), schema: Int(schema))
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
/// One window parsed from `/usage` (usually integer percent); nil reset means unparseable text.
public struct ClaudeProbeWindow: Equatable {
    public var usedPercentage: Double
    public var resetsAt: Int64?
    public var hourOnly: Bool
    public init(usedPercentage: Double, resetsAt: Int64?, hourOnly: Bool = false) {
        self.usedPercentage = usedPercentage; self.resetsAt = resetsAt; self.hourOnly = hourOnly
    }
}
public enum ClaudeSnapshotMerge {
    /// M2: TUI rounds percent to integers and reset times to minutes (sometimes to the hour).
    static func sameAsProbe(old: ClaudeWindow, used: Double, resetsAt: Int64, hourOnly: Bool) -> Bool {
        guard used.isFinite, (0...100).contains(used), old.usedPercentage.isFinite,
              ClaudeSnapshot.validTime(old.resetsAt), ClaudeSnapshot.validTime(resetsAt) else { return false }
        return abs(old.usedPercentage.rounded() - used) < 1 && abs(old.resetsAt - resetsAt) <= (hourOnly ? 5_400 : 120)
    }
    private static func checkExisting(_ existing: ClaudeSnapshot?, now: Int64) throws {
        guard ClaudeSnapshot.validTime(now) else { throw ClaudeReadFailure.clockSkew }
        // Preserve future observations on clock rollback, even within the reader's 300s tolerance.
        if let existing {
            try existing.validate(now: now)
            if existing.observedAt > now { throw ClaudeReadFailure.clockSkew }
        }
    }
    public static func merge(existing: ClaudeSnapshot?, input: ClaudeStatuslineInput, now: Int64) throws -> ClaudeSnapshot? {
        try checkExisting(existing, now: now)
        func merged(_ old: ClaudeWindow?, _ new: ClaudeWindow?) -> ClaudeWindow? {
            guard var new else { return old } // Expired evidence is retained until replaced or cleared.
            new.confirmedAt = nil
            guard let old else { new.changedAt = now; return new }
            let probeSourced = old.confirmedAt != nil && old.confirmedAt == existing?.probedAt
            let same = probeSourced
                ? sameAsProbe(old: old, used: new.usedPercentage.rounded(), resetsAt: new.resetsAt, hourOnly: false)
                : old.usedPercentage == new.usedPercentage && old.resetsAt == new.resetsAt
            new.changedAt = same ? old.changedAt : now
            new.confirmedAt = same ? old.confirmedAt : nil
            return new
        }
        let result = ClaudeSnapshot(bridgeSeenAt: now, probedAt: existing?.probedAt,
                                    fiveHour: merged(existing?.fiveHour, input.fiveHour), sevenDay: merged(existing?.sevenDay, input.sevenDay))
        try result.validate(now: now)
        if let existing, let seen = existing.bridgeSeenAt, now - seen < 30,
           sameIgnoringConfirmation(existing.fiveHour, result.fiveHour), sameIgnoringConfirmation(existing.sevenDay, result.sevenDay) { return nil }
        return result
    }
    private static func sameIgnoringConfirmation(_ a: ClaudeWindow?, _ b: ClaudeWindow?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a else { return false }
        return a.sameValue(b)
    }
    /// Filter parser output before a caller reports success or writes `probedAt`.
    /// M7 permits a dated reset up to 59s in the past (minute rounding); reuse of
    /// an unparseable reset is stricter and requires unchanged, unexpired evidence.
    public static func usableProbe(_ result: ClaudeProbeResult, existing: ClaudeSnapshot?, now: Int64) -> ClaudeProbeResult {
        guard result.status == .success else { return result }
        guard ClaudeSnapshot.validTime(now) else { return ClaudeProbeResult(status: .parseFailed) }
        let trusted: ClaudeSnapshot?
        if let existing, (try? existing.validate(now: now)) != nil, existing.observedAt <= now { trusted = existing }
        else { trusted = nil }
        func usable(_ new: ClaudeProbeWindow?, old: ClaudeWindow?, horizon: Int64) -> ClaudeProbeWindow? {
            guard let new, new.usedPercentage.isFinite, (0...100).contains(new.usedPercentage) else { return nil }
            if let reset = new.resetsAt {
                guard ClaudeSnapshot.validTime(reset), reset > now - 60, reset <= now + horizon else { return nil }
                return new
            }
            guard let old, old.resetsAt > now, abs(old.usedPercentage.rounded() - new.usedPercentage) < 1 else { return nil }
            return ClaudeProbeWindow(usedPercentage: new.usedPercentage, resetsAt: old.resetsAt)
        }
        let five = usable(result.fiveHour, old: trusted?.fiveHour, horizon: ClaudeSnapshot.fiveHourHorizon)
        let week = usable(result.sevenDay, old: trusted?.sevenDay, horizon: ClaudeSnapshot.sevenDayHorizon)
        guard five != nil || week != nil else { return ClaudeProbeResult(status: .parseFailed) }
        return ClaudeProbeResult(status: .success, fiveHour: five, sevenDay: week)
    }
    /// Probe merge: `probedAt=now`; `bridgeSeenAt` is preserved and never fabricated.
    /// Call `usableProbe` before treating a parser result as a successful observation.
    public static func merge(existing: ClaudeSnapshot?, probe: (fiveHour: ClaudeProbeWindow?, sevenDay: ClaudeProbeWindow?), now: Int64) throws -> ClaudeSnapshot {
        try checkExisting(existing, now: now)
        for (window, horizon) in [(probe.fiveHour, ClaudeSnapshot.fiveHourHorizon), (probe.sevenDay, ClaudeSnapshot.sevenDayHorizon)] {
            guard let window else { continue }
            guard window.usedPercentage.isFinite, (0...100).contains(window.usedPercentage) else { throw ClaudeReadFailure.malformed }
            if let reset = window.resetsAt {
                guard ClaudeSnapshot.validTime(reset), reset <= now + horizon else { throw ClaudeReadFailure.clockSkew }
            }
        }
        func merged(_ old: ClaudeWindow?, _ new: ClaudeProbeWindow?) -> ClaudeWindow? {
            guard let new else { return old }
            guard let reset = new.resetsAt else {
                // M7: an unparseable reset may reuse the old one only for an unchanged, unexpired value.
                if var old, old.resetsAt > now, abs(old.usedPercentage.rounded() - new.usedPercentage) < 1 { old.confirmedAt = now; return old }
                return old
            }
            if var old, sameAsProbe(old: old, used: new.usedPercentage, resetsAt: reset, hourOnly: new.hourOnly) {
                old.confirmedAt = now; return old
            }
            return ClaudeWindow(usedPercentage: new.usedPercentage, resetsAt: reset, changedAt: now, confirmedAt: now)
        }
        let result = ClaudeSnapshot(bridgeSeenAt: existing?.bridgeSeenAt, probedAt: now,
                                    fiveHour: merged(existing?.fiveHour, probe.fiveHour), sevenDay: merged(existing?.sevenDay, probe.sevenDay))
        try result.validate(now: now)
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
        let fresh = window.freshAt
        guard ClaudeSnapshot.validTime(fresh) else { return .missing }
        if now > fresh, now - fresh >= staleAfter { return .stale }
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
    public var bridgeAge: Int64? { file.snapshot?.bridgeSeenAt.map { max(0, now - $0) } }
    public var probedAge: Int64? { file.snapshot?.probedAt.map { max(0, now - $0) } }
    /// M4: the probe is the source when it is at least as recent as the bridge.
    public var probeIsSource: Bool {
        guard let snapshot = file.snapshot, let probed = snapshot.probedAt else { return false }
        return probed >= (snapshot.bridgeSeenAt ?? 0)
    }
    public var message: String {
        switch overall {
        case .disabled: return "已关闭"
        case .noSnapshot: return "尚未收到桥接数据"
        case .failed: if case .failed(let failure) = file { return "读取失败 · \(failure.text)" }; return "读取失败"
        case .waiting:
            if probeIsSource { return "等待数据 · 主动查询 \((probedAge ?? 0) / 60) 分钟前运行过，尚未解析到额度" }
            return "等待数据 · 桥接 \((bridgeAge ?? 0) / 60) 分钟前运行过，尚未收到额度字段"
        case .observed, .stale:
            if probeIsSource { return "主动查询 · \((probedAge ?? 0) / 60) 分钟前" }
            return "本地观测 · 桥接 \((bridgeAge ?? 0) / 60) 分钟前"
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
        case .stale: return "旧 · \(max(0, now - (window?.freshAt ?? now)) / 60) 分钟未确认"
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
        return ["claudeFile": p.file.kind, "claudeOverall": p.overall.rawValue, "claudeFiveHourState": p.fiveHourState.rawValue, "claudeSevenDayState": p.sevenDayState.rawValue, "claudeBridgeSeenAgeSeconds": p.bridgeAge.map { $0 as Any } ?? NSNull(), "claudeProbedAgeSeconds": p.probedAge.map { $0 as Any } ?? NSNull()]
    }
}
