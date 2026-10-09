"""Exercise production quota semantics and refuse fabricated reset dates."""
import pathlib
import subprocess
import tempfile
source = (pathlib.Path(__file__).resolve().parents[1] / 'AgentUsage.swift').read_text()
source = source[:source.index('// `--once` :')]
source += r'''
let real: [String: Any] = ["limits": ["session": ["usage": 0, "models": []], "weekly": ["usage": 0.706]], "activity": ["cost": "0.00000", "period": ["type": "last_4_weeks", "starting_at": "2026-09-14T00:00:00Z"]]]
let r = OllamaLimits.parse(real)
assert(r.error == nil && r.sessionInactive && r.session == nil)
assert(abs(r.weekly!.remaining - 29.4) < 0.0001)
assert(r.weekly?.resetsAt == nil, "4-week activity period is not a quota reset")
for value in [0.0, 0.01, 0.5, 1.0] {
    let r = OllamaLimits.parse(["limits": ["session": ["usage": value, "models": [["name": "test", "request_count": 1]]]]])
    assert(r.session != nil && !r.sessionInactive)
    assert(abs(r.session!.remaining - (100 - value * 100)) < 0.0001)
    assert(r.session?.resetsAt == nil)
}
for value: Any in [-1, 70.6, true, "NaN", NSNull()] {
    let r = OllamaLimits.parse(["limits": ["session": ["usage": value]]])
    assert(r.session == nil && r.error != nil, "invalid quota must not turn into a full gauge")
}
assert(OllamaLimits.parse([:]).error != nil)
let explicit = OllamaLimits.parse(["limits": ["weekly": ["usage": 0.2, "resets_at": "2026-10-13T12:00:00Z"]]])
assert(explicit.weekly?.resetsAt != nil)
let counts = OllamaLimits.parse(["range": "7d", "totals": ["request_count": 1611], "buckets": []])
assert(counts.session == nil && counts.weekly == nil && counts.error == nil && !counts.sessionInactive, "counts-only format hides Ollama")
let logs = NSTemporaryDirectory() + "ollama-logs-test"
try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
try! ("2026-10-07T14:40:00+02:00 route=ollama model=\"kimi-k3:cloud\" method=POST path=/v1/responses status=429 duration=1ms result=ok\n"
    + "2026-10-07T14:50:00+02:00 route=chatgpt model=\"gpt-5\" method=POST path=/v1/responses status=429 duration=1ms result=ok\n").write(toFile: logs + "/codex-proxy.log", atomically: true, encoding: .utf8)
try! ("[GIN] 2026/10/07 - 14:45:00 | 429 |  1ms |       127.0.0.1 | POST     \"/v1/responses\"\n").write(toFile: logs + "/server.log", atomically: true, encoding: .utf8)
let hit = OllamaLimits.lastRateLimit(logs: logs)!
assert(hit.model == "kimi-k3:cloud" && hit.date == ISO8601DateFormatter().date(from: "2026-10-07T14:40:00+02:00"), "ChatGPT/Codex 429s ignored")
try! ("[GIN] 2026/10/07 - 23:59:00 | 429 |  1ms |       127.0.0.1 | POST     \"/api/chat\"\n").write(toFile: logs + "/server.log", atomically: true, encoding: .utf8)
assert(OllamaLimits.lastRateLimit(logs: logs)!.model == nil, "direct cloud 429 on /api/chat")
print("PASS: Ollama remaining percentages, inactive session, invalid values, no inferred resets, counts-only hidden, cloud 429 from logs")
'''
with tempfile.TemporaryDirectory(prefix='widget-ollama-test-') as tmp:
    root = pathlib.Path(tmp); path = root / 'main.swift'; path.write_text(source)
    binary = root / 'test'
    subprocess.run(['swiftc', '-module-cache-path', '/tmp/widget-swift-cache', '-swift-version', '5', str(path), '-o', str(binary), '-framework', 'Cocoa', '-framework', 'Network', '-framework', 'UserNotifications', '-framework', 'WidgetKit'], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
