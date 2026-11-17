import Foundation
import CFNetwork
import Darwin

/// Network routing only: never reads Claude settings, credentials, keychains or certificate files.
/// Proxy URLs containing credentials are deliberately unsupported; no URL is exposed in UI/logs.
public struct ClaudeProxyConfiguration: Equatable {
    public enum Source: String { case direct, environment, system, invalid, unsupported }
    public let source: Source
    public let variables: [String: String]
    public var failure: ClaudeProbeStatus? {
        source == .invalid ? .invalidProxy : source == .unsupported ? .unsupportedProxy : nil
    }
    public var summary: String {
        switch source {
        case .direct: return "网络：直连（未检测到 HTTP(S) 代理）"
        case .environment: return "网络：使用启动环境中的 HTTP(S) 代理"
        case .system: return "网络：使用 macOS 系统 HTTP(S) 代理"
        case .invalid: return "网络：代理配置无效或包含认证信息"
        case .unsupported: return "网络：检测到不支持的 PAC/自动发现或代理设置，需配置 HTTP(S) 代理"
        }
    }
    public static func current() -> Self {
        let system = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        return resolve(environment: ProcessInfo.processInfo.environment, system: system)
    }
    /// Pure selection follows the documented Claude CLI precedence; Finder launches fall back
    /// to the system's static HTTP(S) proxy. PAC is not fetched/evaluated. No silent downgrade.
    public static func resolve(environment: [String: String], system: [String: Any]) -> Self {
        func failed(_ source: Source) -> Self { Self(source: source, variables: [:]) }
        func enabled(_ key: String) -> Bool { (system[key] as? NSNumber)?.intValue == 1 }
        func safeURL(_ raw: String) -> String? {
            guard !raw.isEmpty, raw.utf8.count <= 2048,
                  !raw.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
                  let c = URLComponents(string: raw), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
                  let host = c.host, !host.isEmpty,
                  host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-:[]".unicodeScalars.contains($0) }),
                  c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
                  c.path.isEmpty || c.path == "/", let url = c.url,
                  let schemeEnd = raw.range(of: "://") else { return nil }
            // URLComponents.port is also nil for overflowing explicit ports, not just absent ones.
            let authority = raw[schemeEnd.upperBound...].prefix { !"/?#".contains($0) }
            let suffix: Substring
            if authority.hasPrefix("[") {
                guard let close = authority.firstIndex(of: "]") else { return nil }
                suffix = authority[authority.index(after: close)...]
                var address = in6_addr()
                let literal = String(authority.dropFirst().prefix { $0 != "]" })
                guard inet_pton(AF_INET6, literal, &address) == 1 else { return nil }
            } else {
                suffix = authority.lastIndex(of: ":").map { authority[$0...] } ?? authority[authority.endIndex...]
                let name = host.hasSuffix(".") ? String(host.dropLast()) : host
                guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
                if name.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
                    var address = in_addr()
                    guard inet_pton(AF_INET, name, &address) == 1 else { return nil }
                } else {
                    guard name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                        label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
                    }) else { return nil }
                }
            }
            if !suffix.isEmpty {
                let digits = suffix.dropFirst()
                guard suffix.first == ":", !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                      let port = Int(digits), (1...65535).contains(port), c.port == port else { return nil }
            }
            return url.absoluteString
        }
        func result(_ raw: String, source: Source) -> Self {
            guard let url = safeURL(raw) else { return failed(.invalid) }
            var variables = ["HTTPS_PROXY": url]
            var bypass = environment["no_proxy"] ?? environment["NO_PROXY"]
            if bypass == nil, source == .system, let list = system["ExceptionsList"] as? [String] {
                bypass = list.map { $0.hasPrefix("*.") ? String($0.dropFirst()) : $0 }.joined(separator: ",")
            }
            if let bypass, !bypass.isEmpty {
                guard bypass.utf8.count <= 4096, !bypass.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return failed(.invalid) }
                variables["NO_PROXY"] = bypass
            }
            return Self(source: source, variables: variables)
        }
        for key in ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"] {
            if let raw = environment[key], !raw.isEmpty { return result(raw, source: .environment) }
        }
        if enabled("ProxyAutoConfigEnable") || enabled("ProxyAutoDiscoveryEnable") { return failed(.unsupported) }
        for prefix in ["HTTPS", "HTTP"] where enabled(prefix + "Enable") {
            guard let host = system[prefix + "Proxy"] as? String,
                  let number = system[prefix + "Port"] as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  (1...65535).contains(number.doubleValue), !host.isEmpty,
                  !host.contains("/"), !host.contains("@"), !host.contains("%") else { return failed(.invalid) }
            var c = URLComponents(); c.scheme = "http"; c.host = host; c.port = number.intValue
            guard let raw = c.string else { return failed(.invalid) }
            return result(raw, source: .system)
        }
        if enabled("SOCKSEnable") || ["all_proxy", "ALL_PROXY"].contains(where: { environment[$0]?.isEmpty == false }) { return failed(.unsupported) }
        return failed(.direct)
    }
}
