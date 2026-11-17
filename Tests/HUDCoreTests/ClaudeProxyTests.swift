import Foundation
import HUDCore

func testClaudeProxyConfiguration() {
    func resolve(_ env: [String: String] = [:], _ system: [String: Any] = [:]) -> ClaudeProxyConfiguration {
        ClaudeProxyConfiguration.resolve(environment: env, system: system)
    }
    let system: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
                                 "ExceptionsList": ["*.local", "localhost", "127.0.0.1"]]
    expectEqual(resolve().source, .direct)
    expectEqual(resolve().variables, [:])
    let finder = resolve([:], system)
    expectEqual(finder.source, .system)
    expectEqual(finder.variables, ["HTTPS_PROXY": "http://127.0.0.1:7890", "NO_PROXY": ".local,localhost,127.0.0.1"])
    let priority = resolve(["https_proxy": "https://proxy.example:443", "HTTPS_PROXY": "http://other.example:80", "http_proxy": "http://third.example:81", "no_proxy": "localhost,.example.invalid", "ANTHROPIC_API_KEY": "never-forward", "CLAUDECODE": "never-forward"], system)
    expectEqual(priority.source, .environment)
    expectEqual(priority.variables, ["HTTPS_PROXY": "https://proxy.example:443", "NO_PROXY": "localhost,.example.invalid"])
    for key in ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"] {
        expectEqual(resolve([key: "http://localhost:7890"]).variables["HTTPS_PROXY"], "http://localhost:7890")
    }
    for bad in ["http://localhost:999999999999999999999999", "http://localhost:", "http://[gggg]:7890", "http://[1:2:3]:7890", "http://[:::]:7890", "http://bad..example:7890", "http://..:7890", "http://999.1.1.1:7890", "socks5://localhost:7890", "localhost:7890", "http://user:secret@localhost:7890", "http://user@localhost:7890", "http://localhost:7890/a", "http://localhost:7890?x=1", "http://localhost/#x", "http://localhost:0", "http://localhost:65536", "http://localhost:7890\n", "http://localhost:7890\u{0}", "http://local%0ahost:7890", String(repeating: "x", count: 2049)] {
        let result = resolve(["https_proxy": bad], system)
        expectEqual(result.source, .invalid)
        expectEqual(result.variables, [:]) // Never fall through to the system or direct route.
        expectEqual(result.summary.contains("secret"), false)
    }
    expectEqual(resolve(["HTTPS_PROXY": "http://localhost:7890", "NO_PROXY": "*\n"]).source, .invalid)
    expectEqual(resolve(["HTTPS_PROXY": "http://localhost:7890", "NO_PROXY": "*"]).variables["NO_PROXY"], "*")
    expectEqual(resolve([:], ["HTTPEnable": 1, "HTTPProxy": "localhost", "HTTPPort": 8080]).source, .system)
    expectEqual(resolve([:], ["HTTPSEnable": 1, "HTTPSProxy": "localhost", "HTTPSPort": 1.5]).source, .invalid)
    expectEqual(resolve([:], ["HTTPSEnable": 1, "HTTPSProxy": "localhost", "HTTPSPort": 65536]).source, .invalid)
    expectEqual(resolve([:], ["HTTPSEnable": 1, "HTTPSProxy": "u:p@localhost", "HTTPSPort": 7890]).source, .invalid)
    expectEqual(resolve([:], ["ProxyAutoConfigEnable": 1]).source, .unsupported)
    expectEqual(resolve([:], ["ProxyAutoDiscoveryEnable": 1]).source, .unsupported)
    expectEqual(resolve([:], ["SOCKSEnable": 1]).source, .unsupported)
    expectEqual(resolve(["ALL_PROXY": "socks5://localhost:7890"]).source, .unsupported)
    expectEqual(resolve(["https_proxy": "http://localhost:7890"], ["ProxyAutoConfigEnable": 1]).source, .environment)
    expectEqual(resolve(["NO_PROXY": "*"], system).variables["NO_PROXY"], "*")
    expectEqual(resolve(["HTTPS_PROXY": "http://[::1]:7890"]).source, .environment)
    expectEqual(resolve([:], ["HTTPSEnable": 1, "HTTPSProxy": "[::1]", "HTTPSPort": 7890]).source, .system)
    expectEqual(resolve([:], ["HTTPSEnable": 1, "HTTPSProxy": "[gggg]", "HTTPSPort": 7890]).source, .invalid)
    for valid in ["http://proxy.example", "http://proxy.example.", "http://例子.example:7890", "http://192.0.2.1:8080", "http://[2001:db8::1]:7890"] {
        expectEqual(resolve(["HTTPS_PROXY": valid]).source, .environment)
    }
    expectEqual(ClaudeProbeStatus.invalidProxy.stopsAutomaticRetry, true)
    expectEqual(ClaudeProbeStatus.unsupportedProxy.stopsAutomaticRetry, true)
    // Bootstrap reconstructs exactly the normalized network fields without re-reading system state.
    expectEqual(resolve(finder.variables).variables, finder.variables)
}
