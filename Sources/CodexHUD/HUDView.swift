import SwiftUI
import AppKit
import HUDCore

struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

private struct HUDChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct HUDView: View {
    @ObservedObject var store: HUDStore
    var hide: () -> Void
    var showSettings: () -> Void
    var pointerChanged: (Bool) -> Void
    var reveal: () -> Void
    private var warningColor: Color { store.cardSeverity >= .urgent ? .red : .orange }
    var body: some View {
        Group {
            if store.edgeCollapsed { edgeTab } else { fullContent }
        }
        .background(GlassBackground().overlay(Color(red: 0.035, green: 0.045, blue: 0.065).opacity(0.68)).compositingGroup().opacity(1 - store.settings.transparency))
        .clipShape(RoundedRectangle(cornerRadius: store.edgeCollapsed ? 10 : 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: store.edgeCollapsed ? 10 : 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.7))
        .preferredColorScheme(.dark)
        .onHover(perform: pointerChanged)
        .onChange(of: store.selectedSection) { _ in store.layoutChanged?() }
        .onChange(of: store.issue) { _ in store.layoutChanged?() }
        .onChange(of: store.cardSeverity) { _ in store.layoutChanged?() }
        .onChange(of: store.claudeLayoutKey) { _ in store.layoutChanged?() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.edgeCollapsed ? "Codex HUD，靠边已收起" : "Codex HUD")
    }
    private var edgeTab: some View {
        Button(action: reveal) {
            Group {
                if store.settings.claudeEnabled {
                    VStack(spacing: 5) {
                        Text("CX").font(.system(size: 10, weight: .bold))
                        Text(store.weekly?.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—").font(.system(size: 11)).monospacedDigit().opacity(store.quotaStale ? 0.45 : 1)
                        if store.quotaStale { Text("旧").font(.system(size: 8)).foregroundStyle(.orange) }
                        Circle().fill(store.cardSeverity != .normal ? warningColor : store.issue != nil || !store.waiting.isEmpty ? .orange : .clear).frame(width: 5, height: 5)
                        Divider().padding(.horizontal, 7)
                        Text("CL").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.86, green: 0.64, blue: 0.51))
                        Text(store.claude.tabText).font(.system(size: 11)).monospacedDigit().opacity(store.claudeSevenDay == .stale ? 0.45 : 1)
                        if store.claudeSevenDay == .stale { Text("旧").font(.system(size: 8)).foregroundStyle(.orange) }
                        Circle().fill(store.claude.marker == "exhausted" ? .red : store.claude.marker == "warning" ? .orange : .clear).frame(width: 5, height: 5)
                        Image(systemName: store.dockEdge == .left ? "chevron.right" : "chevron.left").font(.system(size: 9))
                    }.foregroundStyle(.white.opacity(0.85))
                } else {
            VStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid").font(.system(size: 15))
                Text(store.weekly?.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                if store.cardSeverity != .normal {
                    Circle().fill(warningColor).frame(width: 6, height: 6)
                } else if store.issue != nil || !store.waiting.isEmpty {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                } else {
                    Image(systemName: store.dockEdge == .left ? "chevron.right" : "chevron.left")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }.foregroundStyle(.white.opacity(0.85))
                }
            }.frame(width: store.edgeLayout.size.width, height: store.edgeLayout.size.height).contentShape(Rectangle())
        }.buttonStyle(.plain).help("鼠标移入展开；拖离边缘恢复浮窗" + (store.settings.claudeEnabled ? "；" + store.claude.tooltip : ""))
            .accessibilityLabel("展开 Codex HUD")
    }
    private var fullContent: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 15) {
            header
            weekly
            tokenOverview
            Divider().overlay(.white.opacity(0.04))
            HStack(spacing: 0) {
                stat(icon: "ticket", value: store.cards?.availableCount.map(String.init) ?? "—", label: "重置卡", accent: store.cardSeverity != .normal ? warningColor : nil) { store.show(.cards) }
                smallDivider
                stat(icon: "circle.fill", value: store.tasksAvailable ? String(store.running.count) : "—", label: "运行中") { store.show(.tasks) }
                smallDivider
                stat(icon: "bubble.left.and.bubble.right", value: store.tasksAvailable ? String(store.waiting.count) : "—", label: "待回复", accent: store.tasksAvailable && !store.waiting.isEmpty ? .orange : nil) { store.show(.tasks) }
            }
            if store.cardSeverity != .normal, let nearest = store.nearestCard {
                Button { store.show(.cards) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: store.cardSeverity >= .urgent ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                        Text("重置卡 · \(Display.expiry(nearest.expiry, now: store.now))").lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(warningColor)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(warningColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            if store.settings.claudeEnabled {
                Divider()
                claudeSection
            }
            if let issue = store.issue {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle")
                    Text(issue)
                    Spacer()
                }.font(.system(size: 10)).foregroundStyle(.orange.opacity(0.9))
            }
            }.background(GeometryReader { geometry in
                Color.clear.preference(key: HUDChromeHeightKey.self, value: geometry.size.height + 36)
            })
            if store.expanded {
                Divider()
                Picker("详情", selection: $store.selectedSection) {
                    ForEach(DetailSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                ScrollView {
                    Group {
                        switch store.selectedSection {
                        case .tokens: tokenDetails
                        case .tasks: taskDetails
                        case .cards: cardDetails
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                }.frame(height: HUDLayout.detailHeight(available: store.availableHeight, chrome: store.chromeHeight + 90))
                HStack {
                    Text("只读 · 本机数据").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.openCodex() } label: { Label("打开 Codex", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                }
            }
        }
        .padding(18)
        .frame(width: 340)
        }
        .frame(width: 340, height: min(store.availableHeight, store.chromeHeight + (store.expanded ? 90 + HUDLayout.detailHeight(available: store.availableHeight, chrome: store.chromeHeight + 90) : 0)))
        .onPreferenceChange(HUDChromeHeightKey.self) { height in
            guard height > 36 else { return } // An absent/collapsed subtree emits the preference default.
            Task { @MainActor in
                if abs(height - store.chromeHeight) > 0.5 { store.chromeHeight = height; store.layoutChanged?() }
            }
        }
    }
    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("✳ CLAUDE").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(red: 0.86, green: 0.64, blue: 0.51))
                Spacer(minLength: 2)
                Text(store.claude.message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            }
            if [.noSnapshot, .failed].contains(store.claudeOverall) {
                Button("查看接入指南 ›", action: showSettings).buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.orange)
            } else {
                claudeRow("5h", window: store.claude.fiveHour)
                claudeRow("W", window: store.claude.sevenDay)
                if store.claude.exhausted { Text("5h 观测为已用尽").font(.system(size: 10)).foregroundStyle(.red).accessibilityLabel("Claude 5 小时额度观测为已用尽") }
            }
        }.help("本地状态栏观测；未变化时间不是服务端更新时间。刷新只重读快照。")
    }
    private func claudeRow(_ label: String, window: ClaudeWindow?) -> some View {
        let state = ClaudeWindowState.evaluate(window: window, now: store.claude.now)
        let remaining = window.map { 100 - $0.usedPercentage } ?? 0
        let color: Color = remaining <= 5 ? .red : remaining <= 20 ? .orange : Color(red: 0.86, green: 0.64, blue: 0.51)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).frame(width: 20, alignment: .leading)
                ProgressView(value: [.observed, .stale].contains(state) ? remaining : 0, total: 100).tint(color).frame(width: 65)
                Text(store.claude.remaining(window) + ([.observed, .stale].contains(state) ? " 剩余" : "")).monospacedDigit()
                Spacer(minLength: 0)
                if [.observed, .stale].contains(state), let window { Text("Reset " + Display.date(Date(timeIntervalSince1970: Double(window.resetsAt)))).font(.system(size: 9)) }
            }.font(.system(size: 11))
            if state != .observed { Text(store.claude.stateText(window)).font(.system(size: 9)).foregroundStyle(.orange) }
        }.opacity(state == .stale ? 0.5 : 1)
    }
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                Text("CODEX").font(.system(size: 11, weight: .semibold)).tracking(2)
            }.overlay(WindowDragRegion()).help("拖动这里移动浮窗")
            Spacer()
            Button { store.refresh() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                    Text(Display.age(store.quotaUpdatedAt, now: store.now)).monospacedDigit()
                }.font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help("额度更新于 \(Display.date(store.quotaUpdatedAt))；点击立即刷新")
            Button { store.toggleDetails() } label: {
                Image(systemName: store.expanded ? "chevron.up" : "chevron.down").frame(width: 20, height: 20)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help(store.expanded ? "收起详情" : "展开详情")
            Button(action: showSettings) { Image(systemName: "gearshape").font(.system(size: 11)).frame(width: 18, height: 20) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("浮窗设置")
            Button(action: hide) { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 12, height: 18) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("隐藏浮窗，菜单栏仍保留")
        }
    }
    private var weekly: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weekly").font(.system(size: 14, weight: .medium))
                Spacer()
                Text(store.weekly?.remainingPercent.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 33, weight: .light, design: .rounded)).monospacedDigit()
                Text("% 剩余").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.09))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white.opacity(store.quotaStale ? 0.25 : 0.65))
                            .frame(width: geometry.size.width * (store.weekly?.remainingPercent ?? 0) / 100)
                    }
            }.frame(height: 4)
            HStack(spacing: 5) {
                Text("Reset").foregroundStyle(.secondary)
                Text(Display.date(store.weekly?.resetDate)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                if store.quotaStale { Text("旧数据").foregroundStyle(.orange) }
            }.font(.system(size: 11)).monospacedDigit()
                .help(store.weekly?.resetDate?.formatted(date: .complete, time: .shortened) ?? "未获得 Weekly reset 时间")
        }
    }
    private var tokenOverview: some View {
        Button { store.show(.tokens) } label: {
            HStack {
                Text("TOKENS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("Today").foregroundStyle(.secondary)
                        Text(Display.tokens(store.tokenReport?.today.total)).fontWeight(.medium).frame(width: 66, alignment: .trailing)
                    }
                    HStack(spacing: 7) {
                        Text("Week").foregroundStyle(.secondary)
                        Text(Display.tokens(store.weeklyTokens?.total)).frame(width: 66, alignment: .trailing)
                    }
                }.font(.system(size: 12)).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary).padding(.leading, 3)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help("展开 Input、Cached input、Output 和 Reasoning 明细")
    }
    private var smallDivider: some View { Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 27) }
    private func stat(icon: String, value: String, label: String, accent: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: icon == "circle.fill" ? 6 : 12))
                    Text(value).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                }.foregroundStyle(accent ?? .white.opacity(0.85))
                Text(label).font(.system(size: 10)).foregroundStyle(accent ?? .secondary)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(label) \(value)")
    }
    private var tokenDetails: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack { Text("本机 Token").fontWeight(.medium); Spacer(); Text("Today"); Text("Week").frame(width: 66, alignment: .trailing) }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            tokenRow("总计", store.tokenReport?.today.total, store.weeklyTokens?.total, strong: true)
            tokenRow("Input", store.tokenReport?.today.input, store.weeklyTokens?.input)
            tokenRow("Cached input", store.tokenReport?.today.cachedInput, store.weeklyTokens?.cachedInput)
            tokenRow("Output", store.tokenReport?.today.output, store.weeklyTokens?.output)
            tokenRow("Reasoning", store.tokenReport?.today.reasoning, store.weeklyTokens?.reasoning)
            Text("Cached input 已含于 Input；Reasoning 已含于 Output。总计为 Input + Output。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Today：本机时区 00:00 起\nWeek：\(Display.date(store.tokenReport?.weekStart)) → 当前 Reset 周期")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.weeklyTokens == nil { Text("获得有效 Weekly reset 时间后，才计算周期 Token。").font(.system(size: 10)).foregroundStyle(.orange) }
            sourceTimes
            if let error = store.tokenError { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
            ForEach(store.tokenReport?.issues ?? [], id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(.orange) }
        }
    }
    private func tokenRow(_ label: String, _ today: Int64?, _ week: Int64?, strong: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(strong ? .primary : .secondary)
            Spacer()
            Text(Display.tokens(today)).frame(width: 62, alignment: .trailing)
            Text(Display.tokens(week)).frame(width: 66, alignment: .trailing)
        }.font(.system(size: 12, weight: strong ? .medium : .regular)).monospacedDigit()
            .help("Today \(today.map(String.init) ?? "未知") · Week \(week.map(String.init) ?? "未知")")
    }
    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.tasksAvailable {
                if !store.waiting.isEmpty { taskGroup("待回复 · \(store.waiting.count)", store.waiting, accent: .orange) }
                if !store.running.isEmpty { taskGroup("运行中 · \(store.running.count)", store.running) }
                if !store.errors.isEmpty { taskGroup("任务异常", store.errors, accent: .orange) }
                if store.waiting.isEmpty && store.running.isEmpty && store.errors.isEmpty {
                    Label("暂无运行中或待回复任务", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            } else {
                Text("无法确认实时任务状态").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                Text("下面是本地未结束记录，可能已停止；不计入运行中或待回复。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                taskGroup("未验证记录 · \(store.fallbackTasks.count)", store.fallbackTasks)
            }
            Divider()
            Text(store.tasksSource).font(.system(size: 10)).foregroundStyle(.secondary)
            Text("仅统计本机已加载的主任务，子 Agent、远程和云端任务不在此计数。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            sourceTimes
        }
    }
    private func taskGroup(_ title: String, _ tasks: [HUDTask], accent: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
            ForEach(tasks) { task in
                Button { store.openCodex(thread: task.id) } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                            Text(task.status.label).font(.system(size: 10)).foregroundStyle(task.status.isWaiting ? .orange : .secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help("在 Codex 中查看任务")
            }
        }
    }
    private var cardDetails: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("可用重置卡 · \(store.cards?.availableCount.map(String.init) ?? "未知")").font(.system(size: 12, weight: .medium))
            ForEach(store.cards?.sorted ?? []) { card in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: card.severity(at: store.now) == .normal ? "ticket" : "exclamationmark.triangle.fill")
                        .foregroundStyle(card.severity(at: store.now) >= .urgent ? .red : card.severity(at: store.now) == .warning ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title ?? "Full reset").font(.system(size: 12, weight: .medium))
                        Text(Display.expiry(card.expiry, now: store.now)).font(.system(size: 11))
                        Text(Display.date(card.expiry)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            if store.cardDetailsStale && store.cardDetailsUpdatedAt != nil { Text("当前显示上次获取的到期明细，待重新验证。").font(.system(size: 10)).foregroundStyle(.orange) }
            if store.cards?.detailsComplete != true { Text("接口尚未提供全部卡片明细，无法确认全部到期时间。").font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Text("按到期时间排序；3 天内提示，24 小时内加强提醒。卡片数量以账户返回值为准。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            sourceTimes
        }
    }
    private var sourceTimes: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("额度更新 \(Display.date(store.quotaUpdatedAt)) · \(Display.age(store.quotaUpdatedAt, now: store.now)) 前")
            Text("任务更新 \(Display.date(store.tasksUpdatedAt)) · \(Display.age(store.tasksUpdatedAt, now: store.now)) 前")
            Text("Token 更新 \(Display.date(store.tokenReport?.updatedAt)) · \(Display.age(store.tokenReport?.updatedAt, now: store.now)) 前")
            if let error = store.quotaError { Text(error).foregroundStyle(.orange) }
        }.font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsView: View {
    @ObservedObject var store: HUDStore
    @ObservedObject var loginItem: LoginItem
    @State var value: HUDConfiguration
    @State private var error: String?
    @State private var existingStatusline = false
    @State private var originalCommandJSON = ""
    @State private var originalShell: ClaudeSetup.Shell? = nil
    @State private var confirmClear = false
    private var executable: String { store.isPreview ? "/Applications/Codex HUD.app/Contents/MacOS/CodexHUD" : Bundle.main.executablePath ?? "" }
    private var canCopy: Bool { !store.isPreview && !executable.isEmpty && !ClaudeSetup.isTranslocated(path: executable) }
    private var generatedWrapper: String? {
        guard let originalShell else { return nil }
        return try? ClaudeSetup.wrapperScript(executable: executable, originalCommandJSON: originalCommandJSON, shell: originalShell)
    }
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Codex HUD 设置").font(.title3.weight(.semibold))
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("登录时自动启动", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .disabled(loginItem.isPreview)
                Text(loginItem.statusText).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if loginItem.status == .requiresApproval {
                    Button("打开系统登录项设置") { loginItem.openSystemSettings() }
                }
                if let error = loginItem.error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("背景透明度")
                    Spacer()
                    Text("\(Int((store.settings.transparency * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }.font(.system(size: 12))
                Slider(value: windowBinding(\.transparency), in: 0...0.8, step: 0.05)
                    .accessibilityLabel("背景透明度")
                Toggle("始终置顶", isOn: windowBinding(\.alwaysOnTop))
                Toggle("靠边自动收起", isOn: windowBinding(\.edgeCollapseEnabled))
                Text("即时生效并保存。透明度只调整背景，文字和数字保持清晰。").font(.caption).foregroundStyle(.secondary)
                Text("拖到左右边缘后，移开鼠标收起，移入展开；拖离边缘恢复普通浮窗。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            claudeSetupSection
            Divider()
            Text("数据连接").font(.system(size: 12, weight: .medium))
            field("Codex 数据目录", text: $value.codexHome, placeholder: "~/.codex")
            field("Codex 可执行文件", text: $value.executable, placeholder: "留空自动查找 Desktop / CLI")
            field("共享 app-server socket", text: $value.sharedSocket, placeholder: "可选，留空使用独立只读连接")
            Toggle("读取 Desktop 本机实时状态（实验接口）", isOn: $value.desktopFeedEnabled)
            Text("如已提供共享 socket，优先读取 app-server 的 thread 状态。实验接口不兼容时显示未验证记录。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("恢复默认") {
                    value = HUDConfiguration()
                    do { try store.applyWindowSettings(value) } catch { self.error = error.localizedDescription }
                }
                Spacer()
                Button("关闭", action: done)
                Button("保存连接并重连") {
                    do { try store.applySettings(value); done() } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 508, height: min(720, max(0, store.availableHeight - 60))).background(Color(nsColor: .windowBackgroundColor))
        .alert("清除 Claude 观测？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { Task { if !(await store.clearClaude()) { error = "清除失败，请检查权限或稍后重试" } } }
        } message: { Text("运行中的来源会重建快照。切换账号前先停止旧来源。此操作不修改 Claude 设置。") }
    }
    private var claudeSetupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude 额度").font(.headline)
            Toggle("显示 Claude 额度", isOn: windowBinding(\.claudeEnabled))
            Text("关闭只影响 HUD 显示，不停止桥接记录。彻底断开请手动恢复/移除桥接配置。").font(.caption)
            Text(store.claude.statusText).font(.caption).foregroundStyle(.secondary)
            Text(executable).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
            if let warning = ClaudeSetup.pathWarning(executable) { Text(warning).font(.caption).foregroundStyle(.orange) }
            Text("移动或删除 app 后配置会失效；请先自行备份原 statusLine。本工具不读取或修改 Claude 设置，不执行粘贴命令。").font(.caption)
            Picker("接入方式", selection: $existingStatusline) {
                Text("我还没有状态栏").tag(false)
                Text("我已有状态栏").tag(true)
            }.pickerStyle(.segmented)
            if existingStatusline {
                Text("粘贴原 command 的完整 JSON 字符串（包含外层双引号），选择原命令使用的 shell；标准 JSON 解码，仅内存生成。").font(.caption)
                TextEditor(text: $originalCommandJSON).font(.system(size: 10, design: .monospaced)).frame(height: 64)
                Picker("原命令 shell", selection: $originalShell) {
                    Text("请明确选择原命令 shell").tag(ClaudeSetup.Shell?.none)
                    ForEach(ClaudeSetup.Shell.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                if let script = generatedWrapper {
                    code(script)
                    Button("复制组合脚本") { copy(script) }.disabled(!canCopy)
                } else { Text("请先明确选择 shell，并输入合法的 JSON 字符串；不会自动执行或测试命令。").font(.caption).foregroundStyle(.orange) }
                Text("保存为你自己的组合脚本后，仅把现有 statusLine.command 改为下方 JSON 字符串；保留 padding、refreshInterval、hideVimModeIndicator 及其他字段。默认保存位置见快速指南。").font(.caption)
                code(ClaudeSetup.wrapperCommandJSONString)
                Button("复制 command JSON 字符串") { copy(ClaudeSetup.wrapperCommandJSONString) }.disabled(!canCopy || generatedWrapper == nil)
                Text("脚本收集 stdin 直到 EOF：此阶段无大小/时间上限，不在桥接 main 的 2 秒预算内；不能保存 NUL。原命令在所选 shell 的独立 -c 上下文运行，继承 cwd/环境。保留原状态栏自己的计时器。仅终止 wrapper 不保证终止后代；真实 Claude 取消语义未验证。").font(.caption).foregroundStyle(.secondary)
            } else {
                let snippet = ClaudeSetup.statusLineJSON(command: ClaudeSetup.bridgeCommand(executable: executable))
                code(snippet)
                Button("复制最小接入片段") { copy(snippet) }.disabled(!canCopy)
                Text("只合并 statusLine 字段，保留 Claude 设置其他内容。有已有状态栏时不要使用此替换片段。").font(.caption)
            }
            Button("清除 Claude 观测…") { confirmClear = true }
            Text("断开：先恢复备份的原 command 和其他配置，再删除组合脚本；不要默认删除整个 statusLine。运行中的来源会重建快照，换账号先停旧来源。").font(.caption)
            Text("排障：Claude Code 首次 API 响应后才可能有额度；需要支持的订阅或 gateway；先信任工作区；组织策略 disableAllHooks / allowManagedHooksOnly 或项目设置可能覆盖状态栏；移动 app 后重新复制；先在 Finder 打开并手动允许（Claude 直接调用的拦截行为未验证）。").font(.caption)
            Text("本地观测，不是账户实时同步；未变化时间不是服务端时间；刷新仅重读快照，官方未承诺计时器会刷新账户额度。仅一个配置来源，多个来源会混写且不能识别账号；其他设备用量等下次观测才反映；不含 Fable 单独周限额，没有 Claude 重置卡。").font(.caption).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func code(_ text: String) -> some View { Text(text).font(.system(size: 9, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6)) }
    private func copy(_ text: String) { guard canCopy else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func windowBinding<Value>(_ keyPath: WritableKeyPath<HUDConfiguration, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: { value in
            var changed = store.settings; changed[keyPath: keyPath] = value
            do { try store.applyWindowSettings(changed) } catch { self.error = error.localizedDescription }
        })
    }
    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
}
