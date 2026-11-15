import AppKit
import SwiftUI
import HUDCore

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private static var isPreview: Bool { ["--demo", "--check-window", "--check-claude"].contains(where: CommandLine.arguments.contains) }
    let store = HUDStore(settings: AppDelegate.isPreview ? .init() : .load(), isPreview: AppDelegate.isPreview)
    let loginItem = LoginItem(isPreview: AppDelegate.isPreview)
    private var panel: HUDPanel!
    private var hosting: NSHostingView<HUDView>!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var powerObservers: [NSObjectProtocol] = []
    private var resizing = false
    private var expandedFrame: NSRect?
    private var dockingWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private let checkingWindows = CommandLine.arguments.contains("--check-window")
    private let renderingDemo = CommandLine.arguments.contains("--demo")
    private let checkingClaude = CommandLine.arguments.contains("--check-claude")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let icon = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Codex HUD") { NSApp.applicationIconImage = icon }
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Codex HUD"; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = store.settings.alwaysOnTop ? .floating : .normal; panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false; panel.delegate = self
        hosting = NSHostingView(rootView: HUDView(store: store,
            hide: { [weak self] in self?.panel.orderOut(nil) },
            showSettings: { [weak self] in self?.showSettings() },
            pointerChanged: { [weak self] inside in self?.pointerChanged(inside) },
            reveal: { [weak self] in self?.revealDock() }))
        hosting.setAccessibilityIdentifier("codex-hud-panel")
        panel.contentView = hosting
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        store.availableHeight = visible.height - 16
        if !Self.isPreview, let position = UserDefaults.standard.string(forKey: "panelOrigin") {
            panel.setFrameOrigin(NSPointFromString(position))
        } else { panel.setFrameOrigin(NSPoint(x: visible.maxX - 364, y: visible.maxY - panel.frame.height - 8)) }
        resizePanel()
        panel.orderFrontRegardless()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        store.layoutChanged = { [weak self] in
            DispatchQueue.main.async { self?.resizePanel() }
        }
        store.summaryChanged = { [weak self] in self?.updateSummary() }
        store.windowSettingsChanged = { [weak self] in
            self?.applyWindowSettings()
        }
        if checkingClaude {
            Task { await runClaudeCheck() }
            return
        }
        if checkingWindows {
            Task { await runWindowChecks() }
            return
        }
        if renderingDemo {
            Task { await renderDemo() }
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        powerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.store.probeSleep() } },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.store.probeWake() } }
        ]
        updateSummary(); store.start()
        scheduleDockCheck()
        if ProcessInfo.processInfo.arguments.contains("--expanded") { store.show(.tasks) }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--capture"), ProcessInfo.processInfo.arguments.count > index + 1 {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in self?.capture(path: path) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        dockingWork?.cancel(); collapseWork?.cancel(); store.stop()
        powerObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; powerObservers = []
    }
    func applicationDidBecomeActive(_ notification: Notification) { loginItem.refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { revealDock(); panel.orderFrontRegardless(); return true }
    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, !resizing, !store.edgeCollapsed else { return }
        rememberPosition()
        store.dockEdge = nil; expandedFrame = nil; collapseWork?.cancel()
        scheduleDockCheck()
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { settingsWindow = nil; scheduleCollapse() }
    }
    private func resizePanel() {
        guard hosting != nil, panel != nil else { return }
        resizing = true; defer { resizing = false }
        hosting.invalidateIntrinsicContentSize(); hosting.layoutSubtreeIfNeeded()
        let visible = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        if abs(store.availableHeight - (visible.height - 16)) > 0.5 { store.availableHeight = visible.height - 16 }
        let previous = expandedFrame ?? panel.frame
        let frame: NSRect
        if store.edgeCollapsed, let edge = store.dockEdge {
            frame = EdgeDocking.collapsedFrame(edge: edge, expanded: previous, in: visible, layout: store.edgeLayout)
        } else {
            frame = EdgeDocking.expandedFrame(edge: store.dockEdge, previous: previous,
                size: NSSize(width: 340, height: max(200, hosting.fittingSize.height)), in: visible)
            expandedFrame = store.dockEdge == nil ? nil : frame
        }
        panel.setFrame(frame, display: true)
    }
    private func applyWindowSettings() {
        panel.level = store.settings.alwaysOnTop ? .floating : .normal
        if !store.settings.edgeCollapseEnabled {
            dockingWork?.cancel(); collapseWork?.cancel()
            store.edgeCollapsed = false; store.dockEdge = nil
            DispatchQueue.main.async { [weak self] in self?.resizePanel() }
        } else if !store.edgeCollapsed { scheduleDockCheck() }
        DispatchQueue.main.async { [weak self] in self?.resizePanel() }
    }
    private func rememberPosition() {
        if !Self.isPreview { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "panelOrigin") }
    }
    private func scheduleDockCheck() {
        dockingWork?.cancel()
        guard store.settings.edgeCollapseEnabled, !store.edgeCollapsed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { self.scheduleDockCheck(); return }
            let visible = self.panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            self.store.dockEdge = EdgeDocking.edge(for: self.panel.frame, in: visible)
            self.expandedFrame = self.store.dockEdge == nil ? nil : self.panel.frame
            if self.store.dockEdge != nil {
                self.resizePanel()
                self.rememberPosition()
                self.scheduleCollapse()
            }
        }
        dockingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func pointerChanged(_ inside: Bool) {
        if inside { collapseWork?.cancel(); revealDock() }
        else { scheduleCollapse() }
    }
    private func scheduleCollapse() {
        collapseWork?.cancel()
        guard store.settings.edgeCollapseEnabled, store.dockEdge != nil, !store.edgeCollapsed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible, self.settingsWindow == nil,
                  self.store.settings.edgeCollapseEnabled, self.store.dockEdge != nil,
                  NSEvent.pressedMouseButtons == 0, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.expandedFrame = self.panel.frame; self.store.edgeCollapsed = true
            DispatchQueue.main.async { [weak self] in self?.resizePanel() }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
    private func revealDock() {
        collapseWork?.cancel()
        guard store.edgeCollapsed else { return }
        store.edgeCollapsed = false
        Task { await store.readClaude() }
        DispatchQueue.main.async { [weak self] in self?.resizePanel() }
    }
    private func updateSummary() {
        statusItem?.button?.title = store.menuSummary
        statusItem?.button?.toolTip = "Codex HUD · Weekly 剩余 / 运行中 / 待回复" + (store.settings.claudeEnabled ? "；" + store.claude.tooltip : "")
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Weekly 剩余 \(store.weekly?.remainingPercent.map { String(Int($0.rounded())) + "%" } ?? "—")", nil)
        add(menu, "Reset \(Display.date(store.weekly?.resetDate))", nil)
        add(menu, "Today Token \(Display.tokens(store.tokenReport?.today.total))", nil)
        add(menu, "重置卡 \(store.cards?.availableCount.map(String.init) ?? "—")", nil)
        if store.cardSeverity != .normal { add(menu, "⚠ \(Display.expiry(store.nearestCard?.expiry, now: store.now))", nil) }
        if let issue = store.issue { add(menu, "⚠ \(issue)", nil) }
        if store.settings.claudeEnabled {
            add(menu, "Claude 5h \(store.claude.remaining(store.claude.fiveHour)) · \(store.claude.stateText(store.claude.fiveHour))\(store.claude.exhausted ? " · 观测为已用尽" : "")", nil)
            add(menu, "Claude Weekly \(store.claude.tabText) · \(store.claude.stateText(store.claude.sevenDay)) · \(store.claude.message)", nil)
        }
        menu.addItem(.separator())
        add(menu, panel.isVisible ? "隐藏浮窗" : "显示浮窗", #selector(togglePanel))
        add(menu, "展开详情", #selector(showDetails))
        let onTop = add(menu, "始终置顶", #selector(toggleOnTop)); onTop.state = store.settings.alwaysOnTop ? .on : .off
        let edge = add(menu, "靠边自动收起", #selector(toggleEdgeCollapse)); edge.state = store.settings.edgeCollapseEnabled ? .on : .off
        add(menu, "立即刷新", #selector(refresh), key: "r")
        add(menu, "打开 Codex", #selector(openCodex))
        add(menu, "设置…", #selector(showSettings), key: ",")
        menu.addItem(.separator())
        add(menu, "退出 Codex HUD", #selector(quit), key: "q")
    }
    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; item.isEnabled = action != nil; menu.addItem(item); return item
    }
    @objc private func togglePanel() { if panel.isVisible { panel.orderOut(nil) } else { revealDock(); panel.orderFrontRegardless() } }
    @objc private func showDetails() { revealDock(); store.show(.tokens); panel.orderFrontRegardless() }
    @objc private func toggleOnTop() {
        var value = store.settings; value.alwaysOnTop.toggle()
        do { try store.applyWindowSettings(value) }
        catch { NSAlert(error: error).runModal() }
    }
    @objc private func toggleEdgeCollapse() {
        var value = store.settings; value.edgeCollapseEnabled.toggle()
        do { try store.applyWindowSettings(value) }
        catch { NSAlert(error: error).runModal() }
    }
    @objc private func refresh() { store.refresh() }
    @objc private func openCodex() { store.openCodex() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showSettings() {
        revealDock()
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 508, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex HUD 设置"; window.isReleasedWhenClosed = false
        window.delegate = self
        loginItem.refresh()
        window.contentView = NSHostingView(rootView: SettingsView(store: store, loginItem: loginItem, value: store.settings, done: { [weak self, weak window] in
            window?.close(); self?.settingsWindow = nil
        }))
        if let content = window.contentView { window.setContentSize(content.fittingSize) }
        window.center(); settingsWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func capture(path: String) {
        resizePanel()
        captureView(hosting, path: path)
    }
    private func renderDemo() async {
        guard let index = CommandLine.arguments.firstIndex(of: "--demo"), CommandLine.arguments.count > index + 1 else { exit(2) }
        let folder = CommandLine.arguments[index + 1]
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try loadDemoData(into: store)
        } catch { fputs("Demo rendering failed\n", stderr); exit(1) }
        func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }
        updateSummary(); resizePanel(); await settle()
        capture(path: folder + "/overview.png")
        store.show(.tokens); await settle()
        capture(path: folder + "/tokens.png")
        store.show(.tasks); await settle()
        capture(path: folder + "/tasks.png")
        store.expanded = false; resizePanel(); await settle()
        store.edgeCollapsed = true; store.dockEdge = .right; resizePanel(); await settle()
        capture(path: folder + "/edge-tab.png")
        store.edgeCollapsed = false; store.dockEdge = nil; resizePanel()
        showSettings(); await settle()
        if let content = settingsWindow?.contentView { captureView(content, path: folder + "/settings.png") }
        exit(0)
    }
    @discardableResult private func captureView(_ view: NSView, path: String?) -> NSBitmapImageRep? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let path, let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
        return bitmap
    }
    #if DEBUG
    private func storeLifecycleChecks() async -> [String: Bool] {
        var results: [String: Bool] = [:]
        for action in ["disable", "clear", "previewSave"] {
            let subject = HUDStore(settings: .init(), isPreview: true)
            var held: CheckedContinuation<ClaudeFileResult, Never>?
            var ready: CheckedContinuation<Void, Never>?
            subject.claudeReadForTesting = {
                await withCheckedContinuation { held = $0; ready?.resume(); ready = nil }
            }
            var worker: Task<Void, Never>?
            await withCheckedContinuation { signal in
                ready = signal
                worker = Task { await subject.readClaude() }
            }
            // A second request must be coalesced, not enqueued behind the suspended read.
            await subject.readClaude()
            if action == "disable" { var value = subject.settings; value.claudeEnabled = false; try? subject.applyWindowSettings(value) }
            if action == "clear" { _ = await subject.clearClaude() }
            if action == "previewSave" { try? subject.applySettings(.init()) }
            let epoch = Int64(subject.now.timeIntervalSince1970)
            held?.resume(returning: .valid(ClaudeSnapshot(bridgeSeenAt: epoch)))
            await worker?.value
            results["inflightReadInvalidated_" + action] = subject.claudeFile == nil
        }
        for action in ["disable", "clear", "settings", "stop"] {
            let subject = HUDStore(settings: .init(), isPreview: true)
            var held: CheckedContinuation<ClaudeProbe.Report, Never>?
            var writes = 0
            subject.claudeProbeForTesting = { await withCheckedContinuation { held = $0 } }
            subject.claudeProbeWriteForTesting = { _, _ in writes += 1; return .written }
            subject.startProbeForTesting(); subject.requestClaudeProbe(manual: true)
            for _ in 0..<100 where held == nil { await Task.yield() }
            if action == "disable" { var value = subject.settings; value.claudeEnabled = false; try? subject.applyWindowSettings(value) }
            if action == "clear" { _ = await subject.clearClaude() }
            if action == "settings" { try? subject.applyClaudeProbeSettings(subject.settings) }
            if action == "stop" { subject.stop() }
            let epoch = Int64(Date().timeIntervalSince1970)
            held?.resume(returning: ClaudeProbe.Report(result: .init(status: .success, fiveHour: .init(usedPercentage: 8, resetsAt: epoch + 3600)), elapsed: 1))
            for _ in 0..<100 where subject.claudeProbing { await Task.yield() }
            results["inflightProbeInvalidated_" + action] = held != nil && !subject.claudeProbing && writes == 0 && subject.claudeProbeReport == nil
        }
        for (key, value) in await claudeProbeCommitChecks() { results[key] = value }
        return results
    }
    #endif
    private func runClaudeCheck() async {
        func argument(_ flag: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > index + 1 else { return nil }
            return CommandLine.arguments[index + 1]
        }
        guard let output = argument("--check-claude"), output.hasPrefix("/"),
              let directory = argument("--claude-snapshot-dir"), directory.hasPrefix("/"),
              let time = argument("--now").flatMap(Int64.init), ClaudeSnapshot.validTime(time) else { exit(2) }
        do { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true); try loadDemoData(into: store) }
        catch { exit(1) }
        store.now = Date(timeIntervalSince1970: Double(time))
        store.settings.claudeEnabled = true
        let reader = ClaudeSnapshotReader()
        store.claudeFile = await reader.read(directory: directory, now: time)
        updateSummary(); resizePanel()
        try? await Task.sleep(nanoseconds: 400_000_000)
        resizePanel()
        let expanded = captureView(hosting, path: output + "/expanded.png")
        let width = hosting.bounds.width
        let scale = panel.backingScaleFactor
        let correctWidth = width == 340 && expanded?.pixelsWide == Int((width * scale).rounded())
        store.edgeCollapsed = true; store.dockEdge = .right; resizePanel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let tab = captureView(hosting, path: output + "/edge-tab.png")
        let correctTab = hosting.bounds.size == store.edgeLayout.size && tab?.pixelsWide == Int((store.edgeLayout.size.width * scale).rounded())
        let geometry: [String: Any] = ["logicalWidth": width, "backingScale": scale, "pixelWidth": expanded?.pixelsWide ?? 0, "exact340pt": correctWidth, "exactTabSize": correctTab]
        do {
            try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output + "/render-check.json"))
            let data = try JSONSerialization.data(withJSONObject: store.claude.fixture, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: output + "/claude-state.json"))
            print(String(decoding: data, as: UTF8.self))
        } catch { exit(1) }
        exit(expanded != nil && tab != nil && correctWidth && correctTab ? 0 : 1)
    }
    /// Exercises real NSPanel state without synthesizing input or changing saved preferences.
    private func runWindowChecks() async {
        var checks: [String: Bool] = [:]
        var geometry: [String: Any] = [:]
        let original = store.settings
        store.settings.claudeEnabled = false
        let singleSize = EdgeTabLayout.codexOnly.size
        let dualSize = EdgeTabLayout.dual.size
        let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let pointer = NSEvent.mouseLocation
        let y = pointer.y < screen.midY ? screen.maxY - 350 : screen.minY + 20
        func settle(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        let output: String? = CommandLine.arguments.firstIndex(of: "--check-window").flatMap { index in
            CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil
        }
        if let output { try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }

        store.settings.alwaysOnTop = false; applyWindowSettings()
        checks["normalWindowLevel"] = panel.level == .normal
        store.settings.alwaysOnTop = true; applyWindowSettings()
        checks["floatingWindowLevel"] = panel.level == .floating
        store.settings.transparency = 0.5
        await settle()
        geometry["initialPanel"] = NSStringFromRect(panel.frame)
        geometry["initialHosting"] = NSStringFromRect(hosting.bounds)
        geometry["initialFitting"] = NSStringFromSize(hosting.fittingSize)
        geometry["chromeHeight"] = store.chromeHeight
        let transparent = captureView(hosting, path: output.map { $0 + "/transparent.png" })
        let scale = Double(transparent?.pixelsWide ?? 340) / Double(hosting.bounds.width)
        let alpha = transparent?.colorAt(x: Int(5 * scale), y: Int(75 * scale))?.alphaComponent ?? -1
        checks["backgroundRendersAtHalfOpacity"] = alpha >= 0.48 && alpha <= 0.52
        var foregroundAlpha: CGFloat = 0
        for pointX in 45...112 {
            let pixelX = Int(Double(pointX) * scale)
            for pointY in 20...40 {
                let pixelY = Int(Double(pointY) * scale)
                let value = transparent?.colorAt(x: pixelX, y: pixelY)?.alphaComponent ?? 0
                foregroundAlpha = max(foregroundAlpha, value)
            }
        }
        checks["foregroundStaysOpaque"] = foregroundAlpha > 0.9
        checks["transparencySettingApplied"] = store.settings.transparency == 0.5
        store.settings.transparency = 0; store.settings.edgeCollapseEnabled = true

        panel.setFrameOrigin(NSPoint(x: screen.maxX - 345, y: y))
        scheduleDockCheck(); await settle(1.3)
        checks["rightEdgeCollapsed"] = store.edgeCollapsed && store.dockEdge == .right && panel.frame.size == singleSize
        if let output { capture(path: output + "/edge-tab.png") }
        pointerChanged(true); await settle()
        geometry["hoverPanel"] = NSStringFromRect(panel.frame)
        geometry["hoverHosting"] = NSStringFromRect(hosting.bounds)
        geometry["hoverFitting"] = NSStringFromSize(hosting.fittingSize)
        checks["hoverRestoresFullWidth"] = !store.edgeCollapsed && panel.frame.width == 340 && panel.frame.height >= 200
        pointerChanged(false); await settle(0.9)
        checks["leavingCollapsesAgain"] = store.edgeCollapsed && panel.frame.width == singleSize.width
        pointerChanged(true); await settle()

        panel.setFrameOrigin(NSPoint(x: screen.midX - 170, y: y))
        scheduleDockCheck(); await settle(0.5)
        checks["dragAwayUndocks"] = store.dockEdge == nil && !store.edgeCollapsed
        panel.setFrameOrigin(NSPoint(x: screen.minX + 5, y: y))
        scheduleDockCheck(); await settle(1.3)
        checks["leftEdgeCollapsed"] = store.edgeCollapsed && store.dockEdge == .left && panel.frame.minX == screen.minX
        store.settings.edgeCollapseEnabled = false; applyWindowSettings(); await settle()
        checks["disablingCollapseRestoresWindow"] = store.dockEdge == nil && !store.edgeCollapsed && panel.frame.width == 340

        store.settings.claudeEnabled = true; store.settings.edgeCollapseEnabled = true
        store.claudeFile = nil; store.dockEdge = .right; expandedFrame = panel.frame
        store.edgeCollapsed = true; resizePanel(); await settle()
        checks["rightEdgeCollapsedDual"] = panel.frame.size == dualSize && panel.frame.maxX == screen.maxX
        checks["dualTabShowsClaudeDash"] = store.claude.tabText == "—" && store.claudeOverall == .noSnapshot
        if let output { capture(path: output + "/dual-tab.png") }
        store.dockEdge = .left; resizePanel(); await settle()
        checks["leftEdgeCollapsedDual"] = panel.frame.size == dualSize && panel.frame.minX == screen.minX
        let anchor = panel.frame.midY
        var disabled = store.settings; disabled.claudeEnabled = false
        try? store.applyWindowSettings(disabled); await settle()
        checks["togglingClaudeWhileCollapsedKeepsAnchor"] = panel.frame.size == singleSize && panel.frame.minX == screen.minX && abs(panel.frame.midY - anchor) <= 1
        updateSummary()
        let menu = NSMenu(); menuWillOpen(menu)
        checks["disabledHidesClaude"] = !menu.items.contains { $0.title.contains("Claude") } && !(statusItem.button?.toolTip?.contains("Claude") ?? true) && !store.menuSummary.contains("C W")
        store.edgeCollapsed = false; store.dockEdge = nil; expandedFrame = nil; resizePanel()
        let smallStore = HUDStore(settings: .init(), isPreview: true)
        smallStore.availableHeight = 260; smallStore.expanded = true
        let small = NSHostingView(rootView: HUDView(store: smallStore, hide: {}, showSettings: {}, pointerChanged: { _ in }, reveal: {}))
        small.setFrameSize(NSSize(width: 340, height: 260)); small.layoutSubtreeIfNeeded()
        checks["syntheticSmallScreenBounded"] = small.fittingSize.height <= 260 && HUDLayout.detailHeight(available: 260, chrome: 450) == 0
        let smallSettings = NSHostingView(rootView: SettingsView(store: smallStore, loginItem: LoginItem(isPreview: true), value: smallStore.settings, done: {}))
        smallSettings.setFrameSize(NSSize(width: 508, height: 200)); smallSettings.layoutSubtreeIfNeeded()
        let smallSettingsImage = captureView(smallSettings, path: output.map { $0 + "/small-settings.png" })
        checks["syntheticSmallSettingsBounded"] = smallSettings.fittingSize.height <= 200 && smallSettingsImage != nil
        #if DEBUG
        checks.merge(await storeLifecycleChecks()) { _, new in new }
        #endif
        let isolated = HUDStore(settings: .init(), isPreview: true)
        try? loadDemoData(into: isolated)
        let baselineIssue = isolated.issue, baselineSeverity = isolated.cardSeverity, baselineCards = isolated.cards?.availableCount
        isolated.claudeFile = .failed(.malformed)
        checks["claudeFailureDoesNotChangeCodex"] = isolated.issue == baselineIssue && isolated.cardSeverity == baselineSeverity && isolated.cards?.availableCount == baselineCards
        let epoch = Int64(isolated.now.timeIntervalSince1970)
        isolated.claudeFile = .valid(ClaudeSnapshot(bridgeSeenAt: epoch, fiveHour: ClaudeWindow(usedPercentage: 100, resetsAt: epoch + 3600, changedAt: epoch), sevenDay: ClaudeWindow(usedPercentage: 23, resetsAt: epoch + 86400, changedAt: epoch)))
        checks["exhaustedIsIsolatedAndTabIsWeekly"] = isolated.claude.exhausted && isolated.claude.tabText == "77%" && isolated.issue == baselineIssue && isolated.cardSeverity == baselineSeverity
        isolated.quotaUpdatedAt = isolated.now.addingTimeInterval(-160)
        checks["codexStaleDoesNotStaleClaude"] = isolated.quotaStale && isolated.claudeSevenDay == .observed
        try? isolated.applySettings(.init()); isolated.start(); isolated.refresh(); isolated.openCodex()
        checks["previewSaveReconnectIsIsolated"] = isolated.isPreview && isolated.quota != nil && isolated.claudeFile != nil
        togglePanel(); checks["hideWindow"] = !panel.isVisible
        togglePanel(); checks["showWindow"] = panel.isVisible
        store.settings = original
        showSettings(); await settle()
        checks["settingsWindowOpens"] = settingsWindow?.isVisible == true
        if let output, let content = settingsWindow?.contentView { captureView(content, path: output + "/settings.png") }
        settingsWindow?.close()
        let result: [String: Any] = ["checks": checks, "geometry": geometry, "renderedBackgroundAlpha": alpha, "renderedForegroundMaxAlpha": foregroundAlpha]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        store.stop()
        exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
}
