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

    init(settings: HUDConfiguration = .load()) {
        self.settings = settings
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
        return "W \(percent)  ·  ●\(tasksAvailable ? String(running.count) : "—")  ◉\(tasksAvailable ? String(waiting.count) : "—")\(issue != nil || cardSeverity != .normal ? " !" : "")"
    }

    func start() {
        wireCallbacks()
        observerRefresh()
        Task { await connect() }
        Task { await scanTokens(force: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }
    func stop() {
        generation += 1; timer?.invalidate(); timer = nil; rpc.stop(); observer.stop()
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
        if tickCount % 5 == 0 {
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
    func show(_ section: DetailSection) {
        selectedSection = section; expanded = true; layoutChanged?()
    }
    func toggleDetails() { expanded.toggle(); layoutChanged?() }
    func applyWindowSettings(_ value: HUDConfiguration) throws {
        var updated = settings
        updated.transparency = min(0.8, max(0, value.transparency))
        updated.alwaysOnTop = value.alwaysOnTop
        updated.edgeCollapseEnabled = value.edgeCollapseEnabled
        try updated.save()
        settings = updated
        windowSettingsChanged?()
    }
    func applySettings(_ value: HUDConfiguration) throws {
        var value = value
        value.transparency = settings.transparency; value.alwaysOnTop = settings.alwaysOnTop
        value.edgeCollapseEnabled = settings.edgeCollapseEnabled
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
