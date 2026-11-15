import AppKit
import Combine
import HUDCore

enum DetailSection: String, CaseIterable { case tokens = "Token", tasks = "任务", cards = "重置卡" }

@MainActor
final class HUDStore: ObservableObject {
    @Published var quota: QuotaSnapshot?
    @Published var quotaUpdatedAt: Date?
    @Published var quotaError: String?
    @Published var cardDetailsUpdatedAt: Date?
    @Published var serverConnected = false
    @Published var tokenReport: TokenReport?
    @Published var tokenError: String?
    @Published var tasks: [HUDTask] = []
    @Published var fallbackTasks: [HUDTask] = []
    @Published var tasksAvailable = false
    @Published var tasksUpdatedAt: Date?
    @Published var tasksSource = "正在连接任务状态"
    @Published var now = Date()
    @Published var expanded = false
    @Published var dockEdge: HUDDockEdge?
    @Published var edgeCollapsed = false
    @Published var selectedSection = DetailSection.tokens
    @Published var refreshing = false
    @Published var settings: HUDConfiguration
    var layoutChanged: (() -> Void)?
    var summaryChanged: (() -> Void)?
    var windowSettingsChanged: (() -> Void)?
    private var rpc = AppServer()
    private var observer: DesktopObserver
    private var scanner: TokenScanner
    private var timer: Timer?
    private var tickCount = 0
    private var connecting = false
    private var tokenScanning = false
    private var tasksReading = false
    private var quotaReading = false
    private var lastQuotaAttempt = Date.distantPast
    private var lastTokenAttempt = Date.distantPast
    private var generation = 0
    private var lastCardDetails: ResetCredits?
    let isPreview: Bool
    @Published var claudeFile: ClaudeFileResult?
    @Published var availableHeight: CGFloat = 850
    @Published var chromeHeight: CGFloat = 450
    private let claudeReader = ClaudeSnapshotReader()
    private var claudeGeneration = 0
    private var claudeReading = false
    private var claudeClearing = false
    private let claudeProbe = ClaudeProbe()
    private var activeClaudeCommit: ClaudeCommitPermit?
    private func invalidateClaudeProbe() {
        activeClaudeCommit?.invalidate(); activeClaudeCommit = nil
        claudeProbe.cancel()
    }
    private var probeSchedule = ClaudeProbeSchedule()
    private var probeStarted = false
    @Published var claudeProbing = false
    @Published var claudeProbeReport: ClaudeProbe.Report?
    @Published var claudeProbeFinishedAt: Date?
    @Published var claudeProbeWriteError = false
    @Published var claudeDetecting = false
    private var uptime: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    var canProbeClaude: Bool { !isPreview && !claudeDetecting && !claudeProbing && settings.claudeEnabled && settings.claudeProbeEnabled && probeSchedule.manualAllowed(uptime: uptime) }
    var claudeProbeText: String {
        if claudeProbing { return "正在向 Claude Code 查询…" }
        if claudeProbeWriteError { return "查询已返回，但未能保存观测" }
        guard let report = claudeProbeReport else { return settings.claudeProbeEnabled ? "等待定时查询" : "主动查询已关闭" }
        if report.result.status == .success { return "✓ \(Display.age(claudeProbeFinishedAt, now: now)) 前查询成功" }
        if let retry = report.result.retryAfter { return report.result.status.text + "，\(Display.date(Date(timeIntervalSince1970: Double(retry)))) 后重试" }
        return report.result.status.text
    }
    #if DEBUG
    var claudeReadForTesting: (() async -> ClaudeFileResult)?
    var claudeClearForTesting: (() async -> Bool)?
    var claudeProbeForTesting: (() async -> ClaudeProbe.Report)?
    var claudeProbeWriteForTesting: ((ClaudeProbeResult, ClaudeCommitPermit) async -> ClaudeWriteResult)?
    func startProbeForTesting() { probeStarted = true; configureProbe() }
    #endif
    var claude: ClaudePresentation { ClaudePresentation(file: claudeFile, now: Int64(now.timeIntervalSince1970), enabled: settings.claudeEnabled) }
    var claudeOverall: ClaudeOverall { claude.overall }
    var claudeFiveHour: ClaudeWindowState { claude.fiveHourState }
    var claudeSevenDay: ClaudeWindowState { claude.sevenDayState }
    var edgeLayout: EdgeTabLayout { settings.claudeEnabled ? .dual : .codexOnly }
    var claudeLayoutKey: String { "\(settings.claudeEnabled)|\(claude.overall)|\(claude.fiveHourState)|\(claude.sevenDayState)|\(claude.remaining(claude.fiveHour))|\(claude.tabText)|\(claude.exhausted)" }

    init(settings: HUDConfiguration = .load(), isPreview: Bool = false) {
        self.settings = settings
        self.isPreview = isPreview
        observer = DesktopObserver(home: settings.homeURL)
        scanner = TokenScanner(home: settings.homeURL)
    }
    var weekly: RateWindow? { quota?.weekly }
    var running: [HUDTask] { tasks.filter { $0.status.isRunning } }
    var waiting: [HUDTask] { tasks.filter { $0.status.isWaiting } }
    var errors: [HUDTask] { tasks.filter { $0.status.type == "systemError" } }
    var cards: ResetCredits? {
        guard let current = quota?.rateLimitResetCredits else { return nil }
        if current.credits != nil { return current }
        if let cached = lastCardDetails, cached.availableCount == current.availableCount,
           let date = cardDetailsUpdatedAt, now.timeIntervalSince(date) < 3600 { return cached }
        return current
    }
    var cardDetailsStale: Bool { quota?.rateLimitResetCredits?.detailsComplete != true || quotaStale }
    var validWeekStart: Date? {
        guard let window = weekly, let start = window.cycleStart, let end = window.resetDate,
              start <= now, now < end else { return nil }
        return start
    }
    var weeklyTokens: TokenTotals? {
        guard let start = validWeekStart, tokenReport?.weekStart == start else { return nil }
        return tokenReport?.weekly
    }
    var nearestCard: ResetCredit? { cards?.sorted.first(where: { $0.expiry != nil }) }
    var cardSeverity: ExpirySeverity { nearestCard?.severity(at: now) ?? .normal }
    var quotaStale: Bool {
        guard let quotaUpdatedAt else { return false }
        return quotaError != nil || now.timeIntervalSince(quotaUpdatedAt) > 150 || (weekly?.resetDate.map { now >= $0 } ?? false)
    }
    var issue: String? {
        if !serverConnected { return quotaUpdatedAt == nil && connecting ? "正在连接…" : "app-server Offline" }
        if quotaStale { return "Quota stale" }
        if quotaError != nil { return "Quota unavailable" }
        if weekly == nil { return "Weekly 暂不可用" }
        if !tasksAvailable { return "任务状态未验证" }
        if cards?.availableCount != 0 && cardDetailsStale { return "重置卡到期信息未验证" }
        if tokenError != nil || !(tokenReport?.issues.isEmpty ?? true) { return "Token 数据不完整" }
        if tokenReport.map({ now.timeIntervalSince($0.updatedAt) > 90 }) ?? false { return "Token stale" }
        if !errors.isEmpty { return "\(errors.count) 个任务异常" }
        return nil
    }
    var menuSummary: String {
        let percent = weekly?.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        return "W \(percent)  ·  ●\(tasksAvailable ? String(running.count) : "—")  ◉\(tasksAvailable ? String(waiting.count) : "—")\(issue != nil || cardSeverity != .normal ? " !" : "")" + (settings.claudeEnabled ? " · " + claude.menu : "")
    }

    func start(allowClaudeProbe: Bool = true) {
        guard !isPreview else { return }
        probeStarted = allowClaudeProbe
        configureProbe()
        Task { await readClaude() }
        wireCallbacks()
        observerRefresh()
        Task { await connect() }
        Task { await scanTokens(force: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }
    func stop() {
        generation += 1; claudeGeneration += 1; claudeFile = nil
        probeStarted = false; activeClaudeCommit?.invalidate(); activeClaudeCommit = nil
        claudeProbe.cancelAndWait(); probeSchedule.invalidate()
        timer?.invalidate(); timer = nil; rpc.stop(); observer.stop()
    }
    private func wireCallbacks() {
        let current = generation
        rpc.onNotification = { [weak self] method in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                if method == "offline" { self.serverConnected = false }
                if method == "account/updated" {
                    self.lastCardDetails = nil; self.cardDetailsUpdatedAt = nil
                    self.quota = nil; self.quotaUpdatedAt = nil
                    await self.refreshQuota()
                }
                if method == "account/rateLimits/updated" { await self.refreshQuota() }
                if method == "thread/status/changed", self.settings.socketPath != nil { await self.readSharedTasks() }
            }
        }
        observer.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.settings.socketPath == nil else { return }
                await self.readDesktopTasks()
            }
        }
    }
    private func tick() {
        now = Date(); tickCount += 1
        requestClaudeProbe()
        if tickCount % 5 == 0 {
            Task { await readClaude() }
            if !serverConnected && !connecting { Task { await connect() } }
            observerRefresh()
            if settings.socketPath != nil { Task { await readSharedTasks() } }
            else { Task { await readDesktopTasks() } }
        }
        let quotaInterval: TimeInterval = expanded || cardDetailsStale ? 15 : 60
        if now.timeIntervalSince(lastQuotaAttempt) >= quotaInterval { Task { await refreshQuota() } }
        if now.timeIntervalSince(lastTokenAttempt) >= 30 { Task { await scanTokens() } }
        summaryChanged?()
    }
    func pollForDiagnostics() { tick() }
    private func observerRefresh() {
        if settings.socketPath == nil && settings.desktopFeedEnabled { observer.refresh() }
    }
    private func connect() async {
        guard !connecting else { return }; connecting = true
        let current = generation
        defer { if current == generation { connecting = false } }
        guard let executable = settings.executablePath else { quotaError = "未找到 Codex CLI，请在连接设置中指定路径"; return }
        do {
            try await rpc.start(executable: executable, codexHome: settings.homeURL, socket: settings.socketPath)
            guard current == generation else { return }
            serverConnected = true
            await refreshQuota()
            if settings.socketPath != nil { await readSharedTasks() }
        } catch {
            guard current == generation else { return }
            serverConnected = false; quotaError = error.localizedDescription
        }
    }
    func refresh() {
        guard !isPreview else { return }
        Task { await readClaude() }
        observerRefresh()
        Task {
            let current = generation
            refreshing = true
            defer { if current == generation { refreshing = false } }
            if !serverConnected { await connect() } else { await refreshQuota() }
            guard current == generation else { return }
            await scanTokens(force: true)
            guard current == generation else { return }
            if settings.socketPath != nil { await readSharedTasks() } else { await readDesktopTasks() }
        }
    }
    private func refreshQuota() async {
        guard serverConnected, !quotaReading else { return }
        quotaReading = true; lastQuotaAttempt = Date()
        let current = generation
        defer { if current == generation { quotaReading = false } }
        do {
            let data = try await rpc.request("account/rateLimits/read", params: ["excludeResetCreditDetails": false])
            let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
            guard current == generation else { return }
            let previousCycle = weekly?.cycleStart
            if quota?.accountId != snapshot.accountId { lastCardDetails = nil; cardDetailsUpdatedAt = nil }
            if let details = snapshot.rateLimitResetCredits, details.credits != nil { lastCardDetails = details; cardDetailsUpdatedAt = Date() }
            quota = snapshot; quotaUpdatedAt = Date(); quotaError = nil
            if previousCycle != weekly?.cycleStart { await scanTokens(force: true) }
        } catch {
            guard current == generation else { return }
            quotaError = error.localizedDescription
            // Force a new sidecar handshake after timeout/EOF; its last values stay visibly stale.
            if quotaError?.contains("超时") == true || quotaError?.contains("断开") == true || quotaError?.contains("退出") == true { serverConnected = false }
        }
        summaryChanged?()
    }
    private func scanTokens(force: Bool = false) async {
        guard !tokenScanning else { return }
        if !force && Date().timeIntervalSince(lastTokenAttempt) < 30 { return }
        tokenScanning = true; lastTokenAttempt = Date()
        let current = generation
        defer { if current == generation { tokenScanning = false } }
        let start = weekly.flatMap { window -> Date? in
            guard let end = window.resetDate, let start = window.cycleStart, start <= Date(), Date() < end else { return nil }
            return start
        }
        do {
            let report = try await scanner.scan(now: Date(), weekStart: start)
            guard current == generation else { return }
            tokenReport = report; tokenError = nil
            if start != validWeekStart { lastTokenAttempt = .distantPast }
        } catch { if current == generation { tokenError = error.localizedDescription } }
    }
    private func readDesktopTasks() async {
        guard settings.socketPath == nil, !tasksReading else { return }
        tasksReading = true
        let current = generation
        defer { if current == generation { tasksReading = false } }
        let snapshot = await observer.snapshot()
        guard current == generation else { return }
        tasks = snapshot.tasks; tasksAvailable = snapshot.available && settings.desktopFeedEnabled
        tasksSource = settings.desktopFeedEnabled ? snapshot.message : "Desktop 实验接口已关闭"
        tasksUpdatedAt = snapshot.updatedAt
        if !tasksAvailable {
            let home = settings.homeURL
            let records = await Task.detached { (try? LocalTasks.unfinished(home: home)) ?? [] }.value
            guard current == generation else { return }
            fallbackTasks = records
        } else { fallbackTasks = [] }
        summaryChanged?()
    }
    private func readSharedTasks() async {
        guard serverConnected, settings.socketPath != nil, !tasksReading else { return }
        tasksReading = true
        let current = generation
        defer { if current == generation { tasksReading = false } }
        do {
            var ids: [String] = [], cursor: String?
            repeat {
                var params: [String: Any] = ["limit": 100]
                if let cursor { params["cursor"] = cursor }
                let data = try await rpc.request("thread/loaded/list", params: params)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let page = object["data"] as? [String] else { throw HUDError.message("任务列表格式不支持") }
                ids += page; cursor = object["nextCursor"] as? String
            } while cursor != nil
            var records: [HUDTask] = []
            for id in Set(ids) {
                let data = try await rpc.request("thread/read", params: ["threadId": id, "includeTurns": false])
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let thread = object["thread"] as? [String: Any],
                      let statusObject = thread["status"] as? [String: Any] else { throw HUDError.message("任务状态格式不支持") }
                if thread["agentNickname"] as? String != nil { continue }
                let status = try JSONDecoder().decode(ThreadStatus.self, from: JSONSerialization.data(withJSONObject: statusObject))
                guard status.isSupported else { throw HUDError.message("任务状态协议字段不支持") }
                records.append(HUDTask(id: id, title: thread["name"] as? String ?? String(id.prefix(8)), status: status, updatedAt: Date()))
            }
            guard current == generation else { return }
            tasks = records; tasksAvailable = true; tasksUpdatedAt = Date(); tasksSource = "共享 app-server · 本机任务"; fallbackTasks = []
        } catch {
            guard current == generation else { return }
            tasksAvailable = false; tasksSource = error.localizedDescription
        }
        summaryChanged?()
    }
    private var probingPermitted: Bool {
        #if DEBUG
        if isPreview { return claudeProbeForTesting != nil && claudeProbeWriteForTesting != nil }
        #endif
        return !isPreview
    }
    private func configureProbe() {
        probeSchedule.configure(enabled: probeStarted && probingPermitted && settings.claudeEnabled && settings.claudeProbeEnabled,
                                interval: settings.claudeProbeInterval, uptime: uptime)
    }
    func probeSleep() { probeSchedule.sleep(); claudeGeneration += 1; invalidateClaudeProbe() }
    func probeWake() { probeSchedule.wake(uptime: uptime) }
    func requestClaudeProbe(manual: Bool = false) {
        guard probeStarted, probingPermitted, !claudeProbing, !claudeDetecting, !claudeClearing,
              probeSchedule.begin(uptime: uptime, now: Int64(Date().timeIntervalSince1970), snapshot: claudeFile?.snapshot,
                                  manual: manual, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled) else { return }
        claudeProbing = true; claudeProbeWriteError = false
        let current = claudeGeneration, runner = claudeProbe
        let token = runner.cancellationToken
        let permit = ClaudeCommitPermit(); activeClaudeCommit = permit
        let options = ClaudeProbe.Options(executable: settings.claudeExecutable, configDirectory: settings.claudeConfigDir)
        Task {
            var report: ClaudeProbe.Report
            #if DEBUG
            if let run = claudeProbeForTesting { report = await run() }
            else { report = await Task.detached { runner.run(options, cancellationToken: token) }.value }
            #else
            report = await Task.detached { runner.run(options, cancellationToken: token) }.value
            #endif
            guard current == claudeGeneration, settings.claudeEnabled, settings.claudeProbeEnabled, probeStarted else {
                claudeProbing = false; probeSchedule.finish(result: .init(status: .cancelled), uptime: uptime, now: Int64(Date().timeIntervalSince1970)); return
            }
            let time = Int64(Date().timeIntervalSince1970)
            if report.result.status == .success {
                report.result = ClaudeSnapshotMerge.usableProbe(report.result, existing: claudeFile?.snapshot, now: time)
                if report.result.status == .success {
                    // The actor serializes commit with clear(); a subsequent clear always wins.
                    let written: ClaudeWriteResult
                    #if DEBUG
                    if let write = claudeProbeWriteForTesting { written = await write(report.result, permit) }
                    else { written = await claudeReader.write(probe: report.result, now: time, permit: permit) }
                    #else
                    written = await claudeReader.write(probe: report.result, now: time, permit: permit)
                    #endif
                    guard current == claudeGeneration, settings.claudeEnabled, settings.claudeProbeEnabled, probeStarted else {
                        claudeProbing = false; probeSchedule.finish(result: .init(status: .cancelled), uptime: uptime, now: time); return
                    }
                    claudeProbeWriteError = written != .written
                    if written == .lockBusy { report.result.status = .busy }
                    else if written != .written { report.result.status = .parseFailed }
                }
            }
            claudeProbeReport = report; claudeProbeFinishedAt = Date(); claudeProbing = false
            probeSchedule.finish(result: report.result, uptime: uptime, now: time, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            await readClaude(); summaryChanged?(); layoutChanged?()
        }
    }
    func applyClaudeProbeSettings(_ value: HUDConfiguration) throws {
        var updated = settings
        updated.claudeProbeEnabled = value.claudeProbeEnabled
        updated.claudeProbeInterval = [900, 1800, 3600].contains(value.claudeProbeInterval) ? value.claudeProbeInterval : 900
        updated.claudeExecutable = value.claudeExecutable?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.claudeConfigDir = value.claudeConfigDir?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.claudeProbeNoticeSeen = value.claudeProbeNoticeSeen
        if !isPreview { try updated.save() }
        claudeGeneration += 1; invalidateClaudeProbe(); settings = updated
        claudeProbeReport = nil; configureProbe(); summaryChanged?(); layoutChanged?()
    }
    func dismissClaudeProbeNotice() {
        var value = settings; value.claudeProbeNoticeSeen = true
        // Acknowledging text must not restart the scheduler or cancel a running query.
        if !isPreview { do { try value.save() } catch { return } }
        settings = value; layoutChanged?()
    }
    func detectClaudeExecutable() async -> String? {
        guard !isPreview, !claudeProbing, !claudeDetecting else { return nil }
        claudeDetecting = true; defer { claudeDetecting = false }
        let runner = claudeProbe
        return await Task.detached { runner.detectExecutable() }.value
    }
    func readClaude() async {
        var permitted = !isPreview
        #if DEBUG
        permitted = permitted || claudeReadForTesting != nil
        #endif
        guard permitted, settings.claudeEnabled, !claudeReading, !claudeClearing else { return }
        claudeReading = true
        let current = claudeGeneration
        let result: ClaudeFileResult
        #if DEBUG
        if let read = claudeReadForTesting { result = await read() }
        else { result = await claudeReader.read(now: Int64(now.timeIntervalSince1970)) }
        #else
        result = await claudeReader.read(now: Int64(now.timeIntervalSince1970))
        #endif
        claudeReading = false
        guard current == claudeGeneration, settings.claudeEnabled, !claudeClearing else { return }
        claudeFile = result; summaryChanged?()
    }
    func clearClaude() async -> Bool {
        claudeGeneration += 1; claudeFile = nil; invalidateClaudeProbe()
        #if DEBUG
        if isPreview, let clear = claudeClearForTesting {
            guard !claudeClearing else { return false }
            claudeClearing = true; defer { claudeClearing = false }
            return await clear()
        }
        #endif
        guard !isPreview else { return true }
        guard !claudeClearing else { return false }
        claudeClearing = true
        defer { claudeClearing = false }
        return await claudeReader.clear()
    }
    func show(_ section: DetailSection) {
        Task { await readClaude() }
        selectedSection = section; expanded = true; layoutChanged?()
    }
    func toggleDetails() { expanded.toggle(); Task { await readClaude() }; layoutChanged?() }
    func applyWindowSettings(_ value: HUDConfiguration) throws {
        var updated = settings
        updated.transparency = min(0.8, max(0, value.transparency))
        updated.alwaysOnTop = value.alwaysOnTop
        updated.edgeCollapseEnabled = value.edgeCollapseEnabled
        updated.claudeEnabled = value.claudeEnabled
        if !isPreview { try updated.save() }
        let changedClaude = settings.claudeEnabled != updated.claudeEnabled
        if changedClaude { claudeGeneration += 1; claudeFile = nil; invalidateClaudeProbe() }
        settings = updated
        if changedClaude { configureProbe() }
        if changedClaude && updated.claudeEnabled { Task { await readClaude() } }
        windowSettingsChanged?(); summaryChanged?()
    }
    func applySettings(_ value: HUDConfiguration) throws {
        var value = value
        value.transparency = settings.transparency; value.alwaysOnTop = settings.alwaysOnTop
        value.edgeCollapseEnabled = settings.edgeCollapseEnabled
        value.claudeEnabled = settings.claudeEnabled
        value.claudeProbeEnabled = settings.claudeProbeEnabled; value.claudeProbeInterval = settings.claudeProbeInterval
        value.claudeExecutable = settings.claudeExecutable; value.claudeConfigDir = settings.claudeConfigDir
        value.claudeProbeNoticeSeen = settings.claudeProbeNoticeSeen
        if isPreview { settings = value; claudeGeneration += 1; invalidateClaudeProbe(); return }
        try value.save(); stop(); settings = value
        rpc = AppServer(); observer = DesktopObserver(home: value.homeURL); scanner = TokenScanner(home: value.homeURL)
        quota = nil; quotaUpdatedAt = nil; tokenReport = nil; tokenError = nil; quotaError = nil
        lastCardDetails = nil; cardDetailsUpdatedAt = nil
        tasks = []; fallbackTasks = []; tasksAvailable = false; serverConnected = false
        connecting = false; tasksReading = false; quotaReading = false; tokenScanning = false; refreshing = false
        lastQuotaAttempt = .distantPast; lastTokenAttempt = .distantPast
        start()
    }
    func openCodex(thread: String? = nil) {
        guard !isPreview else { return }
        if let thread, UUID(uuidString: thread) != nil, let url = URL(string: "codex://threads/\(thread)"), NSWorkspace.shared.open(url) { return }
        for path in ["/Applications/Codex.app", "/Applications/ChatGPT.app"] where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()); return
        }
    }
}

enum Display {
    static func tokens(_ count: Int64?) -> String {
        guard let count else { return "—" }
        if count >= 1_000_000_000 { return String(format: "%.2fB", Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return String(count)
    }
    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
    static func expiry(_ date: Date?, now: Date) -> String {
        guard let date else { return "未提供到期日" }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "已到期 · 待同步" }
        if seconds >= 86400 { return "\(seconds / 86400)d \((seconds % 86400) / 3600)h 后到期" }
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m 后到期" }
        return "\(max(1, seconds / 60))m 后到期"
    }
    static func date(_ value: Date?) -> String {
        guard let value else { return "未提供" }
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"; return formatter.string(from: value)
    }
}
