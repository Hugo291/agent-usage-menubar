"""Production provider parsing and HTTPS requests, using URLProtocol (no network/keychain)."""
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[1] / 'ClaudeUsage.swift').read_text()
source = source[:source.index('// `--once` :')]
source = source.replace('let key = key(p.id)', 'let key = Optional("test-only-key")')
source = source.replace('let config = URLSessionConfiguration.ephemeral', 'let config = URLSessionConfiguration.ephemeral\n        config.protocolClasses = [FixtureProtocol.self]')
source += r'''
final class FixtureProtocol: URLProtocol {
    static var status = 200
    static var body = "{\"data\":{\"usage_daily\":2.5,\"limit\":100,\"limit_remaining\":75,\"free_model_daily_requests\":{\"limit\":50,\"remaining\":38}}}"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        assert(request.httpMethod == "GET")
        assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let p = AddedProvider(name: "OpenRouter", url: "https://openrouter.ai/api/v1/key", openRouter: true)
let r = AddedProviders.read(p)
assert(r.error == nil && r.remaining == 75 && r.dailyCost == 2.5 && r.credit == 75 && r.dailyRequestsRemaining == 38 && r.dailyRequestLimit == 50)
let unlimited: [String: Any] = ["data": ["limit": NSNull(), "limit_remaining": NSNull(), "usage_daily": 0, "free_model_daily_requests": ["limit": 50, "remaining": 50]]]
let unlimitedReading = AddedProviders.parse(unlimited, provider: p)
assert(unlimitedReading.error == nil && unlimitedReading.remaining == nil && unlimitedReading.dailyCost == 0 && unlimitedReading.dailyRequestsRemaining == 50)
let byok: [String: Any] = ["data": ["limit": 10, "limit_remaining": 2, "usage_daily": 1, "byok_usage_daily": 9, "free_model_daily_requests": ["limit": 1000, "remaining": 1000]]]
assert(AddedProviders.parse(byok, provider: p).dailyCost == 1, "do not mislabel BYOK as billed spending")
let custom = AddedProvider(name: "Custom", url: "https://example.com/usage", openRouter: false, remainingPath: "data.remaining", dailyCostPath: "data.cost")
let good: [String: Any] = ["data": ["remaining": "42", "cost": 1.25]]
let c = AddedProviders.parse(good, provider: custom)
assert(c.error == nil && c.remaining == 42 && c.dailyCost == 1.25)
for bad: [String: Any] in [["data": ["remaining": true, "cost": 1]], ["data": ["remaining": 101, "cost": 1]], ["data": ["remaining": 42, "cost": -1]], [:]] {
    let c = AddedProviders.parse(bad, provider: custom)
    assert(c.error != nil && c.remaining == nil && c.dailyCost == nil)
}
assert(AddedProviders.number(["x": "NaN"], path: "x") == nil)
assert(AddedProviders.validURL("http://example.com/usage", openRouter: false) == nil)
assert(AddedProviders.validURL("https://user:secret@example.com/usage", openRouter: false) == nil)
assert(AddedProviders.validURL("https://example.com/usage?key=secret", openRouter: false) == nil)
assert(AddedProviders.validURL("https://evil.example/api/v1/key", openRouter: true) == nil)
assert(AddedProviders.validURL("https://openrouter.ai:444/api/v1/key", openRouter: true) == nil)
assert(AddedProviders.validURL(p.url, openRouter: true) != nil)
FixtureProtocol.status = 401
assert(AddedProviders.read(p).error?.contains("401") == true)
FixtureProtocol.status = 200; FixtureProtocol.body = "not JSON"
assert(AddedProviders.read(p).error != nil)
let encoded = try! JSONEncoder().encode([p, custom])
let restored = try! JSONDecoder().decode([AddedProvider].self, from: encoded)
assert(restored[1].remainingPath == custom.remainingPath)
assert(!String(data: encoded, encoding: .utf8)!.contains("test-only-key"))
print("PASS: OpenRouter request quota, unlimited/BYOK, custom JSON, errors, HTTPS validation, authenticated GET and config round-trip")
'''
with tempfile.TemporaryDirectory(prefix='widget-provider-test-') as tmp:
    root = pathlib.Path(tmp)
    swift = root / 'main.swift'
    swift.write_text(source)
    binary = root / 'test'
    subprocess.run(['swiftc', '-module-cache-path', '/tmp/widget-swift-cache', '-swift-version', '5', str(swift), '-o', str(binary), '-framework', 'Cocoa', '-framework', 'Network', '-framework', 'UserNotifications', '-framework', 'WidgetKit'], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
