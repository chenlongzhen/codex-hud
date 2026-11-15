import Foundation
import HUDCore

/// Synthetic fixtures only: this suite never creates a process or runs Claude.
func claudeUsageTests() {
    let iso = ISO8601DateFormatter()
    func time(_ text: String) -> Int64 { Int64(iso.date(from: text)!.timeIntervalSince1970) }
    let now = time("2026-11-15T11:00:00Z") // 19:00 Asia/Shanghai
    func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/claude-usage-\(name).txt")
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch { expectEqual("fixture \(name): \(error)", "fixture loaded"); return "" }
    }
    func parse(_ text: String) -> ClaudeProbeResult { ClaudeUsageParser.parse(text, now: now) }
    func session(_ value: String, reset: String = "Resets 8pm (Asia/Shanghai)") -> String {
        "Current session\n\(value)% used\n\(reset)\n"
    }
    let layout = parse(fixture("layout"))
    expectEqual(layout.status, .success)
    expectEqual(layout.fiveHour?.usedPercentage, 8)
    expectEqual(layout.fiveHour?.resetsAt, time("2026-11-15T11:59:00Z"))
    expectEqual(layout.sevenDay?.usedPercentage, 23)
    expectEqual(layout.sevenDay?.resetsAt, time("2026-11-20T11:59:00Z"))
    expectEqual(layout.retryAfter, nil)
    let hour = parse(fixture("hour-only"))
    expectEqual(hour.status, .success)
    expectEqual(hour.fiveHour?.resetsAt, time("2026-11-15T12:00:00Z"))
    expectEqual(hour.fiveHour?.hourOnly, true)
    expectEqual(hour.retryAfter, nil)
    expectEqual(parse(fixture("login")).status, .loginRequired)
    expectEqual(parse(fixture("trust")).status, .trustPrompt)
    let limited = parse(fixture("rate-limited"))
    expectEqual(limited.status, .rateLimited)
    expectEqual(limited.retryAfter, time("2026-11-15T11:25:00Z"))
    let missing = parse(fixture("missing"))
    expectEqual(missing.fiveHour, nil)
    expectEqual(missing.sevenDay, nil)
    expectEqual(missing.status, .loading)
    expectEqual(parse(fixture("ambiguous")).status, .parseFailed)
    expectEqual(parse(fixture("ambiguous")).retryAfter, nil)

    for value in ["-1", "+1", "101", "1000", "10000", "100.01", "1e2", "NaN", "inf", ".5", "8..5"] {
        expectEqual(parse(session(value)).fiveHour, nil)
        expectEqual(parse(session(value)).status, .parseFailed)
    }
    for value in ["0", "100", "8.5"] { expectEqual(parse(session(value)).fiveHour?.usedPercentage, Double(value)) }
    expectEqual(parse(session("8") + "9% used").fiveHour, nil)
    expectEqual(parse("CURRENT SESSION\n8 % USED\nResets 8pm (Asia/Shanghai)").fiveHour?.usedPercentage, 8)
    expectEqual(parse("Current session\nCurrent week (Fable)\n18% used").fiveHour, nil)
    expectEqual(parse("Current week (Fable)\n18% used").sevenDay, nil)
    expectEqual(parse("Current session\nApproximate\n13% used").fiveHour, nil)
    expectEqual(parse("Current session\nMCP servers\n13% used").fiveHour, nil)
    expectEqual(parse("Current session\nSession cost\n13% used").fiveHour, nil)
    expectEqual(parse(session("8") + "Current session\nLoading usage data…").fiveHour, nil)
    expectEqual(parse(session("8") + session("9")).fiveHour?.usedPercentage, 9)
    expectEqual(parse(session("8") + "Per-model breakdown unavailable\nrate limited until 7:25pm").status, .success)
    let modelOnly = parse("Current session\nPer-model breakdown unavailable\nrate limited until 7:25pm")
    expectEqual(modelOnly.status, .parseFailed)
    expectEqual(modelOnly.retryAfter, nil)
    expectEqual(parse("Usage is only available to subscribers").status, .notSubscription)
    expectEqual(parse("Usage credits\nNo quota windows").status, .notSubscription)
    expectEqual(parse("Loading usage data…\nUsage credits").status, .loading)
    expectEqual(parse("unknown output").status, .loading)
    expectEqual(parse("Please run /login\n" + session("8")).status, .loginRequired)
    expectEqual(parse(fixture("trust") + "Please run /login").status, .trustPrompt)

    func reset(_ text: String, at stamp: Int64? = nil, zone: String = "Asia/Shanghai", horizon: Int64 = ClaudeSnapshot.fiveHourHorizon, timeOnly: Bool = true) -> Int64? {
        ClaudeUsageParser.inferReset(text, zone: zone, now: stamp ?? now, horizon: horizon, allowTimeOnly: timeOnly)?.0
    }
    expectEqual(reset("8pm"), time("2026-11-15T12:00:00Z"))
    expectEqual(reset("7:59pm"), time("2026-11-15T11:59:00Z"))
    expectEqual(reset("Nov 15 at 8pm"), time("2026-11-15T12:00:00Z"))
    expectEqual(reset("Nov 15 at 7:59pm"), time("2026-11-15T11:59:00Z"))
    expectEqual(reset("12am", at: time("2026-11-15T15:30:00Z")), time("2026-11-15T16:00:00Z"))
    expectEqual(reset("12pm", at: time("2026-11-15T03:30:00Z")), time("2026-11-15T04:00:00Z"))
    expectEqual(reset("Jan 1 at 12am", at: time("2026-12-31T15:30:00Z")), time("2026-12-31T16:00:00Z"))
    expectEqual(reset("8pm", timeOnly: false), nil)
    expectEqual(reset("8pm", zone: "Not/AZone"), nil)
    expectEqual(reset("12pm", zone: "Etc/GMT+8"), nil) // 9h away; timezone digits are accepted, horizon is not.
    expectEqual(reset("4am", zone: "Etc/GMT+8"), time("2026-11-15T12:00:00Z"))
    expectEqual(parse(session("8", reset: "Resets 4am (Etc/GMT+8)")).fiveHour?.resetsAt, time("2026-11-15T12:00:00Z"))
    expectEqual(reset("Nov 22 at 8pm", horizon: ClaudeSnapshot.sevenDayHorizon, timeOnly: false), time("2026-11-22T12:00:00Z"))
    expectEqual(reset("Nov 22 at 8:01pm", horizon: ClaudeSnapshot.sevenDayHorizon, timeOnly: false), nil)
    expectEqual(reset("12:10am"), time("2026-11-15T16:10:00Z"))
    expectEqual(reset("12:11am"), nil)
    expectEqual(reset("7pm"), nil) // Equal now rolls to tomorrow, beyond the 5h horizon.
    expectEqual(reset("Nov 15 at 7pm", at: now + 59), now)
    expectEqual(reset("Nov 15 at 7pm", at: now + 60), nil)
    for invalid in ["0pm", "13pm", "8:60pm", "8:5pm", "8:000pm", "Feb 30 at 8pm", "Nov 0 at 8pm", "Nov 32 at 8pm", "Bog 15 at 8pm", "8pm trailing"] {
        expectEqual(reset(invalid), nil)
    }
    // Calendar arithmetic across spring-forward preserves local time, not +86400 seconds.
    expectEqual(reset("3:30am", at: time("2026-03-07T09:00:00Z"), zone: "America/New_York", horizon: 86400), time("2026-03-08T07:30:00Z"))
    expectEqual(reset("2:30am", at: time("2026-03-08T06:00:00Z"), zone: "America/New_York"), nil)
    for extreme in [Int64.min, Int64.max] {
        expectEqual(reset("8pm", at: extreme), nil)
        expectEqual(reset("8pm", horizon: extreme), nil)
        expectEqual(ClaudeUsageParser.parse(session("8"), now: extreme).status, .parseFailed)
    }
    expectEqual(reset("8pm", horizon: 0), nil)
    expectEqual(parse(session("8", reset: "Resets malformed")).fiveHour?.resetsAt, nil)
    expectEqual(parse(session("8", reset: "Resets 8pm (Wrong/Zone)")).fiveHour?.resetsAt, nil)
    expectEqual(parse(session("8") + "Resets 9pm (Asia/Shanghai)").fiveHour?.resetsAt, nil)

    let dir = "/tmp/hud-synthetic-probe"
    expectEqual(ClaudeUsageParser.trustPromptPathMatches(fixture("trust").components(separatedBy: "\n"), probeDirectory: dir, home: "/tmp"), true)
    expectEqual(ClaudeUsageParser.trustPromptPathMatches(["~/hud-synthetic-probe"], probeDirectory: dir, home: "/tmp"), true)
    expectEqual(ClaudeUsageParser.trustPromptPathMatches(["/tmp/hud-synthetic-", "probe"], probeDirectory: dir, home: "/tmp"), true)
    expectEqual(ClaudeUsageParser.trustPromptPathMatches(["│ " + dir + " │"], probeDirectory: dir, home: "/tmp"), true)
    for lines in [["/tmp/other"], [dir, "/tmp/other"], ["/tmp/hud…"], ["/tmp/hud..."], ["unrelated"], [dir + "-other"], ["/tmp/hud-│synthetic-probe"], [dir + "│"]] {
        expectEqual(ClaudeUsageParser.trustPromptPathMatches(lines, probeDirectory: dir, home: "/tmp"), false)
    }
    for status in [ClaudeProbeStatus.loginRequired, .notSubscription, .notFound, .trustPrompt] { expectEqual(status.stopsAutomaticRetry, true) }
    expectEqual(ClaudeProbeStatus.rateLimited.stopsAutomaticRetry, false)
    testClaudeTerminalRendering()
}

private func testClaudeTerminalRendering() {
    func render(_ input: String, width: Int = 20, height: Int = 4) -> ClaudeUsageScreen {
        var screen = ClaudeUsageScreen(width: width, height: height); screen.feed(input); return screen
    }
    expectEqual(render("abc\rX").screenLines[0], "Xbc")
    expectEqual(render("abc\r\nX").screenLines[1], "X")
    expectEqual(render("abc\u{1b}[2GZ").screenLines[0], "aZc")
    expectEqual(render("abc\u{1b}[2d\u{1b}[1GX").screenLines[1], "X")
    expectEqual(render("abc\u{1b}[2;2HX").screenLines[1], " X")
    expectEqual(render("abc\u{1b}[2D\u{1b}[K").screenLines[0], "a")
    expectEqual(render("abc\r\u{1b}[1CX\u{1b}[1DZ").screenLines[0], "aZc")
    expectEqual(render("abc\u{1b}7\rX\u{1b}8Y").screenLines[0], "XbcY")
    expectEqual(render("abc\u{1b}[s\rX\u{1b}[uY").screenLines[0], "XbcY")
    expectEqual(render("abc\u{1b}[2K").screenLines[0], "")
    expectEqual(render("abc\u{1b}[2J\u{1b}[HZ").screenLines[0], "Z")
    expectEqual(render("abc\u{1b}[1;4rZ").screenLines[0], "abcZ")
    expectEqual(render("a\u{1b}[31mb\u{1b}[0mc").screenLines[0], "abc")
    expectEqual(render("a\u{1b}(B\u{1b}[>4m\u{1b}[<ub").screenLines[0], "ab")
    expectEqual(render("a\u{1b}]0;hidden\u{7}b\u{1b}]title\u{1b}\\c").screenLines[0], "abc")
    expectEqual(render("a\u{1b}Pignored\u{1b}\\b").screenLines[0], "ab")
    let alternate = render("old\u{1b}[?1h\u{1b}[?1049hnew")
    expectEqual(alternate.text.contains("old"), false)
    expectEqual(alternate.screenLines[0], "new")
    expectEqual(alternate.applicationCursorKeys, true)
    expectEqual(render("old\u{1b}[?1049hnew\u{1b}[?1049lfinal").screenLines[0], "final")
    expectEqual(render("\u{1b}[?1h\u{1b}c").applicationCursorKeys, false)
    expectEqual(render("abcde", width: 4).screenLines[1], "e")
    expectEqual(render("a\r\nb\r\nc", height: 2).text, "a\nb\nc")
    expectEqual(render("a\r\nb\r\nc\u{1b}[2J\u{1b}[HX", height: 2).text, "X\n")
    var bounded = ClaudeUsageScreen(width: Int.min, height: Int.min)
    bounded.feed("abc")
    expectEqual(bounded.width, 1); expectEqual(bounded.height, 1)
    let large = ClaudeUsageScreen(width: Int.max, height: Int.max)
    expectEqual(large.width, 512); expectEqual(large.height, 512)
    for final in ["A", "B", "C", "D", "E", "F", "G", "d", "H", "X", "P", "@", "L", "M"] {
        let screen = render("abc\u{1b}[\(Int.max)\(final)Z")
        expectEqual(screen.screenLines.count, 4)
        expectEqual(screen.screenLines.allSatisfy { $0.count <= 20 }, true)
    }
    expectEqual(render("abc\u{1b}[" + String(repeating: "9", count: 100) + "JZ").screenLines[0], "abcZ")
    expectEqual(render("abc\u{1b}[18446744073709551615JZ").screenLines[0], "abcZ")
    let sequence = "a\u{1b}[2G█😀\u{1b}]0;hidden\u{7}z"
    let whole = render(sequence)
    for split in 0...sequence.utf8.count {
        var screen = ClaudeUsageScreen(width: 20, height: 4)
        let bytes = Array(sequence.utf8)
        screen.feed(Array(bytes.prefix(split))); screen.feed(Array(bytes.dropFirst(split)))
        expectEqual(screen.text, whole.text)
    }
    var bytewise = ClaudeUsageScreen(width: 20, height: 4)
    for byte in sequence.utf8 { bytewise.feed([byte]) }
    expectEqual(bytewise.text, whole.text)
    var scroll = ClaudeUsageScreen(width: 20, height: 2)
    scroll.feed(String(repeating: "x\r\n", count: 2100))
    expectEqual(scroll.text.components(separatedBy: "\n").count, 2002)
}
