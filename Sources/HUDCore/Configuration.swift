import Foundation

public struct HUDConfiguration: Codable {
    public var codexHome: String
    public var executable: String
    public var sharedSocket: String
    public var desktopFeedEnabled: Bool
    public var transparency: Double
    public var alwaysOnTop: Bool
    public var edgeCollapseEnabled: Bool
    public init() {
        codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        executable = ""; sharedSocket = ""; desktopFeedEnabled = true
        transparency = 0; alwaysOnTop = true; edgeCollapseEnabled = true
    }
    private enum CodingKeys: String, CodingKey {
        case codexHome, executable, sharedSocket, desktopFeedEnabled, transparency, alwaysOnTop, edgeCollapseEnabled
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        codexHome = try values.decodeIfPresent(String.self, forKey: .codexHome) ?? codexHome
        executable = try values.decodeIfPresent(String.self, forKey: .executable) ?? executable
        sharedSocket = try values.decodeIfPresent(String.self, forKey: .sharedSocket) ?? sharedSocket
        desktopFeedEnabled = try values.decodeIfPresent(Bool.self, forKey: .desktopFeedEnabled) ?? desktopFeedEnabled
        transparency = min(0.8, max(0, try values.decodeIfPresent(Double.self, forKey: .transparency) ?? 0))
        alwaysOnTop = try values.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? alwaysOnTop
        edgeCollapseEnabled = try values.decodeIfPresent(Bool.self, forKey: .edgeCollapseEnabled) ?? edgeCollapseEnabled
    }
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex HUD/settings.json")
    }
    public static func load() -> Self {
        guard let data = try? Data(contentsOf: fileURL), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save() throws {
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }
    public var homeURL: URL { URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath) }
    public var socketPath: String? { sharedSocket.isEmpty ? nil : (sharedSocket as NSString).expandingTildeInPath }
    public var executablePath: String? { AppServer.findExecutable(override: executable.isEmpty ? nil : (executable as NSString).expandingTildeInPath) }
}
