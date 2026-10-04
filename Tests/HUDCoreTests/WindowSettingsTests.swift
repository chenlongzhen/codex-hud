import Foundation
import HUDCore

func testWindowPreferencesPersistAndOldSettingsKeepTheirConnection() throws {
    let old = Data(#"{"codexHome":"/example/codex","executable":"/example/cli","sharedSocket":"","desktopFeedEnabled":false}"#.utf8)
    let previous = try JSONDecoder().decode(HUDConfiguration.self, from: old)
    let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as! [String: Any]
    expectEqual(previous.codexHome, "/example/codex")
    expectEqual(defaults["transparency"] as? Double, 0)
    expectEqual(defaults["alwaysOnTop"] as? Bool, true)
    expectEqual(defaults["edgeCollapseEnabled"] as? Bool, true)

    let custom = Data(#"{"codexHome":"/example/codex","executable":"","sharedSocket":"","desktopFeedEnabled":true,"transparency":0.45,"alwaysOnTop":false,"edgeCollapseEnabled":false}"#.utf8)
    let loaded = try JSONDecoder().decode(HUDConfiguration.self, from: custom)
    let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as! [String: Any]
    expectEqual(saved["transparency"] as? Double, 0.45)
    expectEqual(saved["alwaysOnTop"] as? Bool, false)
    expectEqual(saved["edgeCollapseEnabled"] as? Bool, false)
    let clamped = try JSONDecoder().decode(HUDConfiguration.self, from: Data(#"{"transparency":1.5}"#.utf8))
    expectEqual(clamped.transparency, 0.8)
}
