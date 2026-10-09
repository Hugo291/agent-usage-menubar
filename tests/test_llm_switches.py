"""LlmSwitches: parse ~/.ai/llm-bascules.jsonl (today only, invalid lines ignored) and group by route."""
import pathlib
import subprocess
import tempfile
source = (pathlib.Path(__file__).resolve().parents[1] / 'AgentUsage.swift').read_text()
source = source[:source.index('// `--once` :')]
source += r'''
let now = ISO8601DateFormatter().date(from: "2026-10-08T15:00:00+02:00")!
let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
func iso(_ h: Int, _ m: Int, day: Int = 0) -> String {   // heure LOCALE du jour de `now`
    f.string(from: Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Calendar.current.date(byAdding: .day, value: day, to: now)!)!)
}
let path = NSTemporaryDirectory() + "llm-bascules-test.jsonl"
let lines = [
    "{\"ts\": \"\(iso(14, 3))\", \"source\": \"codex-app\", \"from\": \"kimi-k3:cloud\", \"to\": \"gpt-6-astra\", \"reason\": \"429 quota Ollama Cloud\"}",
    "not json at all",
    "{\"ts\": \"\(iso(9, 0))\", \"source\": \"llm-call\", \"from\": \"kimi-k3:cloud\", \"to\": \"gpt-6-astra\", \"reason\": \"timeout\"}",
    "{\"ts\": \"\(iso(10, 0, day: -1))\", \"from\": \"a\", \"to\": \"b\"}",
    "{\"ts\": \"bad\", \"from\": \"a\", \"to\": \"b\"}",
    "{\"ts\": \"\(iso(11, 0))\", \"from\": \"\", \"to\": \"b\"}",
    "{\"ts\": \"\(iso(12, 0))\", \"source\": \"skill:use-ollama-cloud\", \"from\": \"glm-5.3:cloud\", \"to\": \"qwen3.5\"}",
    "{\"ts\": \"2026-10-08T12:30:00.250+02:00\", \"from\": \"x\", \"to\": \"y\", \"reason\": \"frac\"}",
    "",
]
try! lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
let day = LlmSwitches.today(path: path, now: now)
assert(day.count == 4, "yesterday, bad ts, empty from and non-JSON ignored: \(day.count)")
assert(day.map { $0.ts }.sorted() == day.map { $0.ts }, "sorted by date")
let g = LlmSwitches.grouped(day)
assert(g.count == 3 && g[0].route == "kimi-k3:cloud → gpt-6-astra" && g[0].count == 2, "grouped by route: \(g.map { $0.route })")
assert(g[0].last.reason == "429 quota Ollama Cloud", "reason of the LAST switch of the route")
assert(g[1].route == "x → y" && g[1].last.reason == "frac" && g[2].last.reason == "", "recency order, fractional seconds, missing reason")
assert(LlmSwitches.today(path: "/nonexistent/llm.jsonl", now: now).isEmpty, "missing file → empty")
print("PASS: llm-bascules parsing (today only, invalid lines ignored), grouping by route, last reason")
'''
with tempfile.TemporaryDirectory(prefix='widget-switch-test-') as tmp:
    root = pathlib.Path(tmp); path = root / 'main.swift'; path.write_text(source)
    binary = root / 'test'
    subprocess.run(['swiftc', '-module-cache-path', '/tmp/widget-swift-cache', '-swift-version', '5', str(path), '-o', str(binary), '-framework', 'Cocoa', '-framework', 'Network', '-framework', 'UserNotifications', '-framework', 'WidgetKit'], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
