import Foundation

public struct ThreadStatus: Codable, Equatable {
    public let type: String
    public let activeFlags: [String]?
    public init(type: String, activeFlags: [String]? = nil) { self.type = type; self.activeFlags = activeFlags }
    public var waitingOnInput: Bool { type == "active" && (activeFlags ?? []).contains("waitingOnUserInput") }
    public var waitingOnApproval: Bool { type == "active" && (activeFlags ?? []).contains("waitingOnApproval") }
    public var isWaiting: Bool { waitingOnInput || waitingOnApproval }
    public var isSupported: Bool {
        if type == "active" {
            guard let activeFlags else { return false }
            return Set(activeFlags).isSubset(of: ["waitingOnUserInput", "waitingOnApproval"])
        }
        return ["idle", "notLoaded", "systemError"].contains(type)
    }
    public var isRunning: Bool { isSupported && type == "active" && !isWaiting }
    public var label: String {
        guard isSupported else { return "状态未验证" }
        if waitingOnInput && waitingOnApproval { return "等待回答与批准" }
        if waitingOnApproval { return "等待批准" }
        if waitingOnInput { return "等待回答" }
        switch type {
        case "active": return "运行中"
        case "idle": return "已空闲"
        case "systemError": return "任务异常"
        default: return "状态未验证"
        }
    }
}
public struct HUDTask: Identifiable {
    public let id: String
    public let title: String
    public let status: ThreadStatus
    public let updatedAt: Date?
    public init(id: String, title: String, status: ThreadStatus, updatedAt: Date? = nil) {
        self.id = id; self.title = title; self.status = status; self.updatedAt = updatedAt
    }
}
