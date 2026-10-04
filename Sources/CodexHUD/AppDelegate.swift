import AppKit
import SwiftUI
import HUDCore

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let store = HUDStore(settings: CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--check-window") ? .init() : .load())
    private var panel: HUDPanel!
    private var hosting: NSHostingView<HUDView>!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var resizing = false
    private var expandedFrame: NSRect?
    private var dockingWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private let checkingWindows = CommandLine.arguments.contains("--check-window")
    private let renderingDemo = CommandLine.arguments.contains("--demo")

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
        if !renderingDemo && !checkingWindows, let position = UserDefaults.standard.string(forKey: "panelOrigin") {
            panel.setFrameOrigin(NSPointFromString(position))
        } else { panel.setFrameOrigin(NSPoint(x: visible.maxX - 364, y: visible.maxY - 330)) }
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
        if checkingWindows {
            Task { await runWindowChecks() }
            return
        }
        if renderingDemo {
            Task { await renderDemo() }
            return
        }
        updateSummary(); store.start()
        scheduleDockCheck()
        if ProcessInfo.processInfo.arguments.contains("--expanded") { store.show(.tasks) }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--capture"), ProcessInfo.processInfo.arguments.count > index + 1 {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in self?.capture(path: path) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { dockingWork?.cancel(); collapseWork?.cancel(); store.stop() }
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
        let previous = expandedFrame ?? panel.frame
        let frame: NSRect
        if store.edgeCollapsed, let edge = store.dockEdge {
            frame = EdgeDocking.collapsedFrame(edge: edge, expanded: previous, in: visible)
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
    }
    private func rememberPosition() {
        if !checkingWindows && !renderingDemo { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "panelOrigin") }
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
        DispatchQueue.main.async { [weak self] in self?.resizePanel() }
    }
    private func updateSummary() {
        statusItem?.button?.title = store.menuSummary
        statusItem?.button?.toolTip = "Codex HUD · Weekly 剩余 / 运行中 / 待回复"
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Weekly 剩余 \(store.weekly?.remainingPercent.map { String(Int($0.rounded())) + "%" } ?? "—")", nil)
        add(menu, "Reset \(Display.date(store.weekly?.resetDate))", nil)
        add(menu, "Today Token \(Display.tokens(store.tokenReport?.today.total))", nil)
        add(menu, "重置卡 \(store.cards?.availableCount.map(String.init) ?? "—")", nil)
        if store.cardSeverity != .normal { add(menu, "⚠ \(Display.expiry(store.nearestCard?.expiry, now: store.now))", nil) }
        if let issue = store.issue { add(menu, "⚠ \(issue)", nil) }
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
        window.contentView = NSHostingView(rootView: SettingsView(store: store, value: store.settings, done: { [weak self, weak window] in
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
    /// Exercises real NSPanel state without synthesizing input or changing saved preferences.
    private func runWindowChecks() async {
        var checks: [String: Bool] = [:]
        let original = store.settings
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
        checks["rightEdgeCollapsed"] = store.edgeCollapsed && store.dockEdge == .right && panel.frame.width == 36 && panel.frame.height == 108
        if let output { capture(path: output + "/edge-tab.png") }
        pointerChanged(true); await settle()
        checks["hoverRestoresFullWidth"] = !store.edgeCollapsed && panel.frame.width == 340 && panel.frame.height >= 200
        pointerChanged(false); await settle(0.9)
        checks["leavingCollapsesAgain"] = store.edgeCollapsed && panel.frame.width == 36
        pointerChanged(true); await settle()

        panel.setFrameOrigin(NSPoint(x: screen.midX - 170, y: y))
        scheduleDockCheck(); await settle(0.5)
        checks["dragAwayUndocks"] = store.dockEdge == nil && !store.edgeCollapsed
        panel.setFrameOrigin(NSPoint(x: screen.minX + 5, y: y))
        scheduleDockCheck(); await settle(1.3)
        checks["leftEdgeCollapsed"] = store.edgeCollapsed && store.dockEdge == .left && panel.frame.minX == screen.minX
        store.settings.edgeCollapseEnabled = false; applyWindowSettings(); await settle()
        checks["disablingCollapseRestoresWindow"] = store.dockEdge == nil && !store.edgeCollapsed && panel.frame.width == 340

        togglePanel(); checks["hideWindow"] = !panel.isVisible
        togglePanel(); checks["showWindow"] = panel.isVisible
        store.settings = original
        showSettings(); await settle()
        checks["settingsWindowOpens"] = settingsWindow?.isVisible == true
        if let output, let content = settingsWindow?.contentView { captureView(content, path: output + "/settings.png") }
        settingsWindow?.close()
        let result: [String: Any] = ["checks": checks, "renderedBackgroundAlpha": alpha, "renderedForegroundMaxAlpha": foregroundAlpha]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        store.stop()
        exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
}
