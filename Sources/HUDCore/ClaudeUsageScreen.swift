import Foundation

/// Minimal terminal emulator for the `claude /usage` TUI. Pure: no IO, no process creation.
/// Renders printable text onto a width×height grid plus bounded scrollback. Every CSI/ESC/OSC
/// sequence is consumed whole; unsupported ones never leak parameter characters as text.
public struct ClaudeUsageScreen {
    public let width: Int
    public let height: Int
    public static let maxScrollback = 2_000
    private var lines: [[Character]]
    private var row = 0, col = 0
    private var saved = (0, 0)
    /// DECCKM (`CSI ?1h`) seen: cursor keys must be sent as `ESC O x`.
    public private(set) var applicationCursorKeys = false
    private var pending: [UInt8] = []      // incomplete UTF-8
    private enum Mode { case ground, escape, escapeIntermediate, csi, osc, oscEscape, string, stringEscape }
    private var mode = Mode.ground
    private var csiBuffer: [Character] = []
    private var csiOverflow = false

    public init(width: Int = 120, height: Int = 40) {
        // Public/test callers cannot create negative grids or unbounded allocations.
        self.width = min(512, max(1, width)); self.height = min(512, max(1, height))
        lines = Array(repeating: [], count: self.height)
    }
    private var top: Int { lines.count - height }

    public mutating func feed(_ data: Data) { feed(Array(data)) }
    public mutating func feed(_ bytes: [UInt8]) {
        pending.append(contentsOf: bytes)
        // Decode the longest complete UTF-8 prefix; keep a trailing partial scalar for later.
        var end = pending.count
        var back = 0
        while back < min(3, end) {
            let byte = pending[end - 1 - back]
            if byte & 0xC0 == 0x80 { back += 1; continue }
            let need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if need > back + 1 { end -= back + 1 }
            break
        }
        let text = String(decoding: pending[0..<end], as: UTF8.self)
        pending.removeFirst(end)
        for character in text.unicodeScalars { process(character) }
    }
    public mutating func feed(_ text: String) { feed(Array(text.utf8)) }

    private mutating func process(_ scalar: Unicode.Scalar) {
        let value = scalar.value
        switch mode {
        case .ground:
            switch value {
            case 0x1B: mode = .escape
            case 0x0D: col = 0
            case 0x0A, 0x0B, 0x0C: lineFeed()
            case 0x08: col = max(0, col - 1)
            case 0x09: col = min(width - 1, (col / 8 + 1) * 8)
            case 0x9B: mode = .csi; csiBuffer = []; csiOverflow = false
            case 0..<0x20, 0x7F, 0x80..<0xA0: break
            default: put(Character(scalar))
            }
        case .escape:
            switch value {
            case 0x5B: mode = .csi; csiBuffer = []; csiOverflow = false                 // [
            case 0x5D: mode = .osc                                  // ]
            case 0x50, 0x5F, 0x5E, 0x58: mode = .string             // P _ ^ X
            case 0x37: saved = (row, col); mode = .ground           // 7
            case 0x38: (row, col) = saved; clampCursor(); mode = .ground // 8
            case 0x63: reset(); applicationCursorKeys = false; mode = .ground // c
            case 0x44: lineFeed(); mode = .ground                   // D
            case 0x45: col = 0; lineFeed(); mode = .ground          // E
            case 0x4D: row = max(0, row - 1); mode = .ground        // M
            case 0x20...0x2F: mode = .escapeIntermediate            // ( ) # etc.
            case 0x1B: mode = .escape
            default: mode = .ground                                 // other ESC x dropped
            }
        case .escapeIntermediate:
            if (0x20...0x2F).contains(value) { break }
            mode = .ground                                          // final byte consumed
        case .csi:
            if (0x40...0x7E).contains(value) { if !csiOverflow { csi(final: Character(scalar)) }; mode = .ground }
            else if value == 0x1B { mode = .escape }
            else if (0x20...0x3F).contains(value) {
                if csiBuffer.count < 64 { csiBuffer.append(Character(scalar)) } else { csiOverflow = true }
            }
            else if value < 0x20 { /* C0 inside CSI: ignored */ }
            else { mode = .ground }
        case .osc:
            if value == 0x07 || value == 0x9C { mode = .ground }
            else if value == 0x1B { mode = .oscEscape }
        case .oscEscape:
            mode = value == 0x5C ? .ground : .osc
        case .string:
            if value == 0x9C { mode = .ground } else if value == 0x1B { mode = .stringEscape }
        case .stringEscape:
            mode = value == 0x5C ? .ground : .string
        }
    }
    private mutating func reset() {
        lines = Array(repeating: [], count: height); row = 0; col = 0; saved = (0, 0)
    }
    private mutating func clampCursor() { row = min(max(0, row), height - 1); col = min(max(0, col), width - 1) }
    private mutating func lineFeed() {
        if row < height - 1 { row += 1; return }
        lines.append([])
        if lines.count > height + Self.maxScrollback { lines.removeFirst(lines.count - height - Self.maxScrollback) }
    }
    private mutating func put(_ character: Character) {
        if col >= width { col = 0; lineFeed() }
        let index = top + row
        while lines[index].count < col { lines[index].append(" ") }
        if col < lines[index].count { lines[index][col] = character } else { lines[index].append(character) }
        col += 1
    }
    private mutating func eraseLine(_ index: Int, from start: Int, to end: Int) {
        guard start < lines[index].count else { return }
        let stop = min(end, lines[index].count)
        if stop >= lines[index].count { lines[index].removeSubrange(start..<lines[index].count) }
        else { for i in start..<stop { lines[index][i] = " " } }
    }
    private mutating func csi(final: Character) {
        var text = String(csiBuffer)
        var privateMarker: Character?
        if let first = text.first, "?<>=".contains(first) { privateMarker = first; text.removeFirst() }
        if text.contains(where: { (" "..."/").contains($0) }) { return } // intermediates: drop
        let parts = text.split(separator: ";", omittingEmptySubsequences: false).map { $0.split(separator: ":", omittingEmptySubsequences: false).first ?? "" }
        let params = parts.map { Int($0) }
        guard zip(parts, params).allSatisfy({ $0.0.isEmpty || $0.1 != nil }) else { return }
        // Clamp before cursor arithmetic; hostile CSI may contain Int.max.
        func p(_ i: Int) -> Int { min(max(width, height), max(1, i < params.count ? (params[i] ?? 1) : 1)) }
        func raw(_ i: Int) -> Int { i < params.count ? (params[i] ?? 0) : 0 }
        if let marker = privateMarker {
            guard marker == "?", final == "h" || final == "l" else { return }
            for mode in params.compactMap({ $0 }) {
                if mode == 1 { applicationCursorKeys = final == "h" }
                if [47, 1047, 1049].contains(mode) { reset() } // alternate screen switch: parse only the last active screen
            }
            return
        }
        switch final {
        case "A": row = max(0, row - p(0))
        case "B", "e": row = min(height - 1, row + p(0))
        case "C", "a": col = min(width - 1, col + p(0))
        case "D": col = max(0, col - p(0))
        case "E": row = min(height - 1, row + p(0)); col = 0
        case "F": row = max(0, row - p(0)); col = 0
        case "G", "`": col = min(width - 1, p(0) - 1)
        case "d": row = min(height - 1, p(0) - 1)
        case "H", "f": row = min(height - 1, p(0) - 1); col = min(width - 1, p(1) - 1)
        case "J":
            switch raw(0) {
            case 0:
                eraseLine(top + row, from: col, to: Int.max)
                for r in (row + 1)..<height { lines[top + r] = [] }
            case 1:
                for r in 0..<row { lines[top + r] = [] }
                eraseLine(top + row, from: 0, to: col + 1)
            default: // 2/3: whole screen and the scrollback, so stale frames never parse
                lines = Array(repeating: [], count: height)
            }
        case "K":
            switch raw(0) {
            case 0: eraseLine(top + row, from: col, to: Int.max)
            case 1: eraseLine(top + row, from: 0, to: col + 1)
            default: lines[top + row] = []
            }
        case "X": eraseLine(top + row, from: col, to: col + p(0))
        case "P":
            let index = top + row
            if col < lines[index].count { lines[index].removeSubrange(col..<min(lines[index].count, col + p(0))) }
        case "@":
            let index = top + row
            if col < lines[index].count { lines[index].insert(contentsOf: Array(repeating: " ", count: min(p(0), width)), at: col); if lines[index].count > width { lines[index].removeLast(lines[index].count - width) } }
        case "L":
            for _ in 0..<min(p(0), height - row) { lines.insert([], at: top + row); lines.remove(at: lines.count - 1) }
        case "M":
            for _ in 0..<min(p(0), height - row) { lines.remove(at: top + row); lines.append([]) }
        case "s": saved = (row, col)
        case "u": (row, col) = saved; clampCursor()
        default: break // m (SGR), r (DECSTBM), c, q, n, t, ...: no-op
        }
    }
    /// Rendered text: scrollback plus screen, trailing spaces trimmed.
    public var text: String {
        lines.map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")
    }
    public var screenLines: [String] { lines.suffix(height).map { String($0) } }
}

public enum ClaudeProbeStatus: String, Codable, CaseIterable {
    case success, trustPrompt, trustFailed, loginRequired, notSubscription, rateLimited, timeout, parseFailed, loading
    case outputOverflow, notFound, untrustedExecutable, needsNode, probeDirNotEmpty, probeDirUntrusted, busy, spawnFailed, cancelled
    case invalidProxy, unsupportedProxy
    /// Statuses that stop automatic retries until the user acts (B5/M8).
    public var stopsAutomaticRetry: Bool {
        [.trustPrompt, .trustFailed, .loginRequired, .notSubscription, .notFound, .untrustedExecutable, .needsNode, .probeDirNotEmpty, .probeDirUntrusted, .invalidProxy, .unsupportedProxy].contains(self)
    }
    public var text: String {
        switch self {
        case .success: return "成功"
        case .trustPrompt: return "需要信任探测目录：请在终端于该目录运行一次 claude"
        case .trustFailed: return "自动信任探测目录失败"
        case .loginRequired: return "需要登录：请在终端运行 claude 并登录"
        case .notSubscription: return "当前登录不是订阅账户（或为 API key），/usage 不提供额度"
        case .rateLimited: return "被限流"
        case .timeout: return "查询超时，请检查网络/HTTP(S)代理"
        case .invalidProxy: return "代理配置无效或包含认证信息，请检查 HTTP(S) 代理"
        case .unsupportedProxy: return "不支持仅 PAC/SOCKS/自动发现的代理，请配置 HTTP(S) 代理"
        case .parseFailed, .loading: return "无法解析 /usage 输出"
        case .outputOverflow: return "输出异常"
        case .notFound: return "未找到 claude（未安装或路径不同）"
        case .untrustedExecutable: return "claude 路径不可信"
        case .needsNode: return "claude 需要 node 但未找到"
        case .probeDirNotEmpty: return "探测目录不为空，已拒绝执行"
        case .probeDirUntrusted: return "探测目录不可信"
        case .busy: return "正在查询"
        case .spawnFailed: return "无法启动 claude"
        case .cancelled: return "已取消"
        }
    }
}

public struct ClaudeProbeResult: Equatable {
    public var status: ClaudeProbeStatus
    public var fiveHour: ClaudeProbeWindow?
    public var sevenDay: ClaudeProbeWindow?
    public var retryAfter: Int64?
    public init(status: ClaudeProbeStatus, fiveHour: ClaudeProbeWindow? = nil, sevenDay: ClaudeProbeWindow? = nil, retryAfter: Int64? = nil) {
        self.status = status; self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.retryAfter = retryAfter
    }
}

/// Pure parser over rendered `/usage` text.
public enum ClaudeUsageParser {
    enum Heading: Equatable { case session, weekAll, weekOther, approximate, perModel, mcp, sessionCost, contributing, credits }
    static func normalized(_ line: String) -> String {
        line.lowercased().filter { !$0.isWhitespace }
    }
    static func heading(_ line: String) -> Heading? {
        // Strip leading box/indent characters before comparing.
        let n = String(normalized(line).drop(while: { !$0.isLetter }))
        if n.hasPrefix("currentsession") { return .session }
        if n.hasPrefix("currentweek(allmodels)") { return .weekAll }
        if n.hasPrefix("currentweek(") { return .weekOther }
        if n.hasPrefix("approximate") { return .approximate }
        if n.hasPrefix("per-model") { return .perModel }
        if n.hasPrefix("mcpservers") { return .mcp }
        if n.hasPrefix("what'scontributing") || n.hasPrefix("what’scontributing") { return .contributing }
        if n.hasPrefix("usagecredits") { return .credits }
        if n.hasPrefix("session"), !n.hasPrefix("sessions") { return .sessionCost }
        return nil
    }
    /// Lines of the last block started by `wanted`, up to the next known heading.
    static func lastBlock(_ lines: [String], _ wanted: Heading) -> [String]? {
        var result: [String]?
        var current: [String]?
        for line in lines {
            if let h = heading(line) {
                if current != nil { result = current }
                current = h == wanted ? [line] : nil
            } else if current != nil { current!.append(line) }
        }
        return current ?? result
    }
    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func group(_ match: NSTextCheckingResult, _ i: Int, _ text: String) -> String? {
        guard i < match.numberOfRanges, let range = Range(match.range(at: i), in: text) else { return nil }
        return String(text[range])
    }
    static let percentPattern = #"(?<![\p{L}\p{N}_.+\-])(\d{1,3}(?:\.\d+)?)\s*%\s*used\b"#
    /// M6: exactly one percentage per block; M7: deterministic reset inference.
    static func window(_ block: [String]?, now: Int64, horizon: Int64, allowTimeOnly: Bool) -> ClaudeProbeWindow? {
        guard let block else { return nil }
        let text = block.joined(separator: "\n")
        let percents = matches(percentPattern, text)
        guard percents.count == 1, let raw = group(percents[0], 1, text), let used = Double(raw), used.isFinite, (0...100).contains(used) else { return nil }
        let resets = matches(#"rese(?:ts?|s)?\s*([^\n()]+?)\s*\(([A-Za-z0-9_/+-]+)\)"#, text)
        var reset: (Int64, Bool)?
        if resets.count == 1, let when = group(resets[0], 1, text), let zone = group(resets[0], 2, text) {
            reset = inferReset(when, zone: zone, now: now, horizon: horizon, allowTimeOnly: allowTimeOnly)
        }
        return ClaudeProbeWindow(usedPercentage: used, resetsAt: reset?.0, hourOnly: reset?.1 ?? false)
    }
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    /// Returns (unix seconds, hourOnly). All inference happens in the shown time zone.
    public static func inferReset(_ text: String, zone: String, now: Int64, horizon: Int64, allowTimeOnly: Bool) -> (Int64, Bool)? {
        // Bound arithmetic and Foundation date construction before using public input.
        guard ClaudeSnapshot.validTime(now), (1...691_200).contains(horizon),
              let tz = TimeZone(identifier: zone) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let found = matches(#"^(?:([A-Za-z]{3})\s*(\d{1,2})\s*at\s*)?(\d{1,2})(?::(\d{1,2}))?\s*(am|pm)$"#, trimmed)
        guard found.count == 1 else { return nil }
        let m = found[0]
        guard let hourText = group(m, 3, trimmed), let hour12 = Int(hourText), (1...12).contains(hour12),
              let meridiem = group(m, 5, trimmed)?.lowercased() else { return nil }
        let minuteText = group(m, 4, trimmed)
        if let minuteText { guard minuteText.count == 2 else { return nil } }
        let minute = minuteText.flatMap(Int.init) ?? 0
        guard (0...59).contains(minute) else { return nil }
        let hour = (hour12 % 12) + (meridiem == "pm" ? 12 : 0)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = tz
        let nowDate = Date(timeIntervalSince1970: TimeInterval(now))
        func at(_ y: Int, _ mo: Int, _ d: Int) -> Int64? {
            var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = hour; c.minute = minute; c.second = 0
            guard let date = calendar.date(from: c) else { return nil }
            let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            guard back.year == y, back.month == mo, back.day == d,
                  back.hour == hour, back.minute == minute else { return nil } // reject invalid dates and DST gaps
            let seconds = date.timeIntervalSince1970
            guard seconds >= Double(ClaudeSnapshot.minTime), seconds <= Double(ClaudeSnapshot.maxTime) else { return nil }
            return Int64(seconds)
        }
        let today = calendar.dateComponents([.year, .month, .day], from: nowDate)
        guard let year = today.year, let month = today.month, let day = today.day else { return nil }
        let result: Int64
        if let monthText = group(m, 1, trimmed)?.lowercased() {
            guard let mo = months.firstIndex(of: monthText).map({ $0 + 1 }), let dText = group(m, 2, trimmed), let d = Int(dText), (1...31).contains(d) else { return nil }
            let candidates = [year, year + 1].compactMap { at($0, mo, d) }.filter { $0 > now - 60 && $0 <= now + horizon }
            guard candidates.count == 1 else { return nil }
            result = candidates[0]
        } else {
            guard allowTimeOnly, var candidate = at(year, month, day) else { return nil }
            if candidate <= now {
                // Calendar day addition (not +86400) so DST transitions stay correct.
                guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: nowDate)) else { return nil }
                let c = calendar.dateComponents([.year, .month, .day], from: next)
                guard let y = c.year, let mo = c.month, let d = c.day, let value = at(y, mo, d) else { return nil }
                candidate = value
            }
            guard candidate > now, candidate <= now + horizon else { return nil }
            result = candidate
        }
        return (result, minuteText == nil)
    }
    static func contains(_ text: String, _ needle: String) -> Bool { normalized(text).contains(normalized(needle)) }

    public static func isTrustPrompt(_ text: String) -> Bool {
        contains(text, "trust this folder") || contains(text, "Quick safety check") || contains(text, "Do you trust the files")
    }
    /// The panel finished loading (local stats or credits are drawn) and is not "Loading".
    static func panelLoaded(_ text: String) -> Bool {
        (contains(text, "Approximate") || contains(text, "What's contributing") || contains(text, "Usage credits")) && !contains(text, "Loading usage")
    }
    public static func parse(_ text: String, now: Int64) -> ClaudeProbeResult {
        guard ClaudeSnapshot.validTime(now) else { return ClaudeProbeResult(status: .parseFailed) }
        if isTrustPrompt(text) { return ClaudeProbeResult(status: .trustPrompt) }
        if contains(text, "Not logged in") || contains(text, "Please run /login") || contains(text, "Please run") && contains(text, "login") || contains(text, "/login") && !contains(text, "Current session") {
            return ClaudeProbeResult(status: .loginRequired)
        }
        let lines = text.components(separatedBy: "\n")
        let fiveBlock = lastBlock(lines, .session), weekBlock = lastBlock(lines, .weekAll)
        let five = window(fiveBlock, now: now, horizon: ClaudeSnapshot.fiveHourHorizon, allowTimeOnly: true)
        let week = window(weekBlock, now: now, horizon: ClaudeSnapshot.sevenDayHorizon, allowTimeOnly: false)
        if five != nil || week != nil { return ClaudeProbeResult(status: .success, fiveHour: five, sevenDay: week) }
        let n = normalized(text)
        if n.range(of: #"(onlyavailable|availableonly|isonly)[^\n]{0,80}subscri"#, options: .regularExpression) != nil
            || n.range(of: #"subscri[^\n]{0,40}(only|required)"#, options: .regularExpression) != nil {
            return ClaudeProbeResult(status: .notSubscription)
        }
        // A malformed/ambiguous quota percentage is a parse failure, not a rate limit.
        let hasQuotaPercent = [fiveBlock, weekBlock].compactMap { $0 }.contains {
            !matches(#"%\s*used\b"#, $0.joined(separator: "\n")).isEmpty
        }
        // Exclude the whole per-model block, including wrapped limit messages.
        var perModel = false
        let mainLines = lines.filter { line in
            if let title = heading(line) { perModel = title == .perModel }
            return !perModel
        }
        if !hasQuotaPercent, let limitLine = mainLines.first(where: { normalized($0).contains("ratelimited") }) {
            var retry: Int64?
            if let m = matches(#"until\s*([^()\n]+?)\s*(?:\(([A-Za-z0-9_/+-]+)\))?\s*(?:[).]|$)"#, limitLine).first, let when = group(m, 1, limitLine) {
                let zone = group(m, 2, limitLine) ?? TimeZone.current.identifier
                retry = inferReset(when, zone: zone, now: now, horizon: 86_400 * 8, allowTimeOnly: true)?.0
            }
            return ClaudeProbeResult(status: .rateLimited, retryAfter: retry)
        }
        let hasHeadings = lines.contains { [.session, .weekAll].contains(heading($0)) }
        if !hasHeadings && panelLoaded(text) { return ClaudeProbeResult(status: .notSubscription) }
        if contains(text, "Loading usage") || !hasHeadings { return ClaudeProbeResult(status: .loading) }
        return ClaudeProbeResult(status: .parseFailed)
    }
    /// S3: the path shown in the trust prompt (wrapped lines joined) must equal the probe
    /// directory or its `~/` form exactly; any ellipsis or any other path aborts.
    public static func trustPromptPathMatches(_ screenLines: [String], probeDirectory: String, home: String) -> Bool {
        let forms = [probeDirectory] + (probeDirectory.hasPrefix(home + "/") ? ["~" + probeDirectory.dropFirst(home.count)] : [])
        let borders = "│┃┆┇┊┋╎╏║"
        // Strip a paired frame only, never arbitrary characters from a path.
        let lines = screenLines.map { line -> String in
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               borders.contains(first), borders.contains(last) {
                value.removeFirst(); value.removeLast()
                value = value.trimmingCharacters(in: .whitespaces)
            }
            return value
        }
        if lines.contains(where: { $0.contains("…") || $0.contains("...") }) { return false }
        var matched = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("/") || line.hasPrefix("~/") else { index += 1; continue }
            var joined = line, used = 0, ok = forms.contains(joined)
            while !ok, used < 2, index + used + 1 < lines.count, !lines[index + used + 1].isEmpty {
                used += 1; joined += lines[index + used]; ok = forms.contains(joined)
            }
            guard ok else { return false } // another path, or a partial/garbled one
            matched = true
            index += used + 1
        }
        return matched
    }
}
