import Foundation

public struct TokenTotals: Codable, Equatable {
    public var input: Int64 = 0
    public var cachedInput: Int64 = 0
    public var output: Int64 = 0
    public var reasoning: Int64 = 0
    /// Cached input is a subset of input, and reasoning is a subset of output.
    public var total: Int64 { Self.add(input, output) }
    public init(input: Int64 = 0, cachedInput: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0) {
        self.input = max(0, input); self.cachedInput = max(0, cachedInput)
        self.output = max(0, output); self.reasoning = max(0, reasoning)
    }
    public init(json: [String: Any]) {
        input = max(0, (json["input_tokens"] as? NSNumber)?.int64Value ?? 0)
        cachedInput = max(0, (json["cached_input_tokens"] as? NSNumber)?.int64Value ?? 0)
        output = max(0, (json["output_tokens"] as? NSNumber)?.int64Value ?? 0)
        reasoning = max(0, (json["reasoning_output_tokens"] as? NSNumber)?.int64Value ?? 0)
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: add(lhs.input, rhs.input), cachedInput: add(lhs.cachedInput, rhs.cachedInput),
             output: add(lhs.output, rhs.output), reasoning: add(lhs.reasoning, rhs.reasoning))
    }
    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : value
    }
    fileprivate func wouldOverflow(adding other: Self) -> Bool {
        let pairs = [(input, other.input), (cachedInput, other.cachedInput), (output, other.output), (reasoning, other.reasoning)]
        if pairs.contains(where: { $0.0.addingReportingOverflow($0.1).overflow }) { return true }
        return (input + other.input).addingReportingOverflow(output + other.output).overflow
    }
    fileprivate func subtracting(_ other: Self) -> Self {
        Self(input: max(0, input - other.input), cachedInput: max(0, cachedInput - other.cachedInput),
             output: max(0, output - other.output), reasoning: max(0, reasoning - other.reasoning))
    }
}

/// Reduces cumulative session snapshots to newly consumed tokens.
public struct TokenLedger {
    private var previous: TokenTotals?
    public init() {}
    public mutating func consume(cumulative: TokenTotals, last: TokenTotals?) -> TokenTotals {
        defer { previous = cumulative }
        guard let previous else { return last ?? cumulative }
        if cumulative == previous { return TokenTotals() }
        if cumulative.input < previous.input || cumulative.output < previous.output {
            // A resumed/compacted session may restart its counters. Only the final request is new.
            return last ?? TokenTotals()
        }
        return cumulative.subtracting(previous)
    }
}

public struct TokenEvent {
    public let date: Date
    public let key: String
    public let usage: TokenTotals
    public init(date: Date, key: String, usage: TokenTotals) { self.date = date; self.key = key; self.usage = usage }
}

public struct TokenReport {
    public let today: TokenTotals
    public let weekly: TokenTotals?
    public let weekStart: Date?
    public let scannedFiles: Int
    public let issues: [String]
    public let updatedAt: Date
    public static func aggregate(_ events: [TokenEvent], now: Date, calendar: Calendar, weekStart: Date?, scannedFiles: Int = 0, issues: [String] = []) -> Self {
        var today = TokenTotals(), weekly = TokenTotals(), seen = Set<String>(), overflowed = false
        let todayStart = calendar.startOfDay(for: now)
        for event in events where event.date <= now && seen.insert(event.key).inserted {
            if event.date >= todayStart {
                overflowed = overflowed || today.wouldOverflow(adding: event.usage)
                today = today + event.usage
            }
            if let weekStart, event.date >= weekStart {
                overflowed = overflowed || weekly.wouldOverflow(adding: event.usage)
                weekly = weekly + event.usage
            }
        }
        return Self(today: today, weekly: weekStart == nil ? nil : weekly, weekStart: weekStart,
                    scannedFiles: scannedFiles, issues: issues + (overflowed ? ["Token 计数超出支持范围，统计不完整"] : []), updatedAt: now)
    }
}

/// Reads append-only JSONL incrementally; content and credentials are never persisted.
public actor TokenScanner {
    private struct FileState {
        var size: UInt64 = 0
        var modified: Date = .distantPast
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var ledger = TokenLedger()
        var sessionID: String = ""
        var bornAt: Date?
        var events: [TokenEvent] = []
        var malformed = 0
        var skippingOversizedLine = false
    }
    private var files: [String: FileState] = [:]
    private var lowerBound: Date?
    private let home: URL
    private let fractionalFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private let secondFormatter = ISO8601DateFormatter()
    public init(home: URL) { self.home = home }

    public func scan(now: Date, weekStart: Date?, calendar: Calendar = .current) throws -> TokenReport {
        let since = min(calendar.startOfDay(for: now), weekStart ?? now)
        if lowerBound.map({ since < $0 }) ?? true { files.removeAll(); lowerBound = since }
        let manager = FileManager.default
        let sessionRoot = home.appendingPathComponent("sessions")
        guard manager.isReadableFile(atPath: sessionRoot.path) else { throw HUDError.message("无法读取本地 sessions 目录") }
        var discovered = Set<String>(), issues: [String] = []
        for root in [sessionRoot, home.appendingPathComponent("archived_sessions")] {
            guard manager.fileExists(atPath: root.path) else { continue }
            var enumerationFailed = false
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return true }) else {
                issues.append("部分 session 目录不可读"); continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                do {
                    let attributes = try manager.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                    let modified = attributes[.modificationDate] as? Date ?? .distantPast
                    if modified < since && files[url.path] == nil { continue }
                    discovered.insert(url.path)
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    var state = files[url.path] ?? FileState()
                    if inode != state.inode || size < state.size || (size == state.size && modified != state.modified) { state = FileState() }
                    if size != state.size || modified != state.modified {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: state.offset)
                        var pending = Data()
                        var consumed = state.offset
                        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                            pending.append(chunk)
                            while let end = pending.range(of: Data([10]))?.lowerBound {
                                let line = Data(pending[..<end])
                                consumed += UInt64(pending.distance(from: pending.startIndex, to: end) + 1)
                                pending.removeSubrange(...end)
                                if !state.skippingOversizedLine {
                                    if line.count <= 16 * 1024 * 1024 { autoreleasepool { parse(line, state: &state, since: since) } }
                                    else { state.malformed += 1 }
                                }
                                state.skippingOversizedLine = false
                                state.offset = consumed
                            }
                            // Bound memory even when a damaged/large record has no newline yet.
                            // Keep the skip state across scans, then resume after its terminator.
                            if pending.count > 16 * 1024 * 1024 || state.skippingOversizedLine {
                                if !state.skippingOversizedLine { state.malformed += 1 }
                                state.skippingOversizedLine = true
                                consumed += UInt64(pending.count); pending = Data(); state.offset = consumed
                            }
                        }
                        state.size = size; state.modified = modified; state.inode = inode
                        files[url.path] = state
                    }
                } catch { issues.append("1 个 session 读取失败") }
            }
            if enumerationFailed { issues.append("部分 session 目录不可读") }
        }
        files = files.filter { discovered.contains($0.key) }
        let malformed = files.values.reduce(0) { $0 + $1.malformed }
        if malformed > 0 { issues.append("\(malformed) 条 Token 记录格式不支持") }
        return TokenReport.aggregate(files.values.flatMap(\.events), now: now, calendar: calendar, weekStart: weekStart,
                                     scannedFiles: files.count, issues: issues)
    }

    private func parse(_ line: Data, state: inout FileState, since: Date) {
        guard line.range(of: Data("\"token_count\"".utf8)) != nil || line.range(of: Data("\"session_meta\"".utf8)) != nil else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let payload = object["payload"] as? [String: Any] else { state.malformed += 1; return }
        if object["type"] as? String == "session_meta" {
            state.sessionID = payload["id"] as? String ?? state.sessionID
            state.bornAt = date(payload["timestamp"] as? String ?? object["timestamp"] as? String)
            return
        }
        guard object["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else { return }
        guard let total = info["total_token_usage"] as? [String: Any],
              let dateText = object["timestamp"] as? String, let date = date(dateText) else { state.malformed += 1; return }
        let cumulative = TokenTotals(json: total)
        let last = (info["last_token_usage"] as? [String: Any]).map(TokenTotals.init(json:))
        let delta = state.ledger.consume(cumulative: cumulative, last: last)
        // Forks can copy historical snapshots. They establish a baseline, but are not new consumption.
        guard date >= since, date >= (state.bornAt ?? .distantPast), delta.total > 0 else { return }
        let key = "\(state.sessionID)|\(dateText)|\(cumulative.input)|\(cumulative.output)|\(cumulative.cachedInput)|\(cumulative.reasoning)"
        state.events.append(TokenEvent(date: date, key: key, usage: delta))
    }

    private func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return fractionalFormatter.date(from: text) ?? secondFormatter.date(from: text)
    }
}
