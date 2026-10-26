import Combine
import ServiceManagement

@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?
    let isPreview: Bool

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
        refresh()
    }

    var isEnabled: Bool { status == .enabled }

    var statusText: String {
        switch status {
        case .enabled: return "已开启，登录 Mac 后自动启动。"
        case .requiresApproval: return "请在系统设置的登录项中允许 Codex HUD。"
        case .notFound: return "系统尚未找到登录项，可开启此开关进行注册。"
        case .notRegistered: return "开启后，登录 Mac 时自动启动 Codex HUD。"
        @unknown default: return "无法确认登录项状态，请查看系统设置。"
        }
    }

    func refresh() {
        guard !isPreview else { return }
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        guard !isPreview else { return }
        error = nil
        refresh()
        do {
            if enabled {
                if status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else if status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = "无法更改登录项：\(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() {
        guard !isPreview else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}
