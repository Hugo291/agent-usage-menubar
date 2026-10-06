"""Exercise the production fetch failure path with isolated provider data."""
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[1] / 'ClaudeUsage.swift').read_text()
start = source.index('    static func fetch(previous:')
end = source.index('// MARK: - Quotas Ollama Cloud', start)
fetch = source[start:end]
fetch = fetch.replace('let c = Ccusage.read()', 'let c = Ccusage.Data(codexTodayCost: 12, codexTodayTokens: 1000)')
fetch = fetch.replace('let cl = CodexLimits.read()', 'let cl = CodexLimits.Snapshot(fiveHour: Limit(utilization: 30, resetsAt: nil), sevenDay: Limit(utilization: 19, resetsAt: nil), plan: "plus", asOf: Date())')
fetch = fetch.replace('if let ol = OllamaLimits.read()', 'if false, let ol = OllamaLimits.read()')
fetch = fetch.replace('readLocal(into: &u)', '// Local probe disabled in isolated test')
fetch = fetch.replace('guard let token = Auth.ensureToken()', 'guard let token = Optional<String>.none')
source = source[:start] + fetch + source[end:]
start = source.index('// `--once` :')
source = source[:start] + '''
var previous = Usage()
previous.fiveHour = Limit(utilization: 42, resetsAt: nil)
Fetcher.fetch(previous: previous) { result in
    guard case .partial(let u, _) = result else { fatalError("expected partial result") }
    assert(u.fiveHour?.utilization == 42, "preserve cached Claude quota")
    assert(u.codexFiveHour?.remaining == 70)
    assert(u.codexSevenDay?.remaining == 81)
    assert(u.codexTodayCost == 12)
    assert(u.codexTodayTokens == 1000)
    print("PASS: Claude auth failure preserves its cache and refreshes Codex quotas, cost and tokens")
    exit(0)
}
RunLoop.main.run()
'''
with tempfile.TemporaryDirectory(prefix='widget-partial-test-') as tmp:
    root = pathlib.Path(tmp)
    swift = root / 'test.swift'
    swift.write_text(source)
    binary = root / 'test'
    subprocess.run(['swiftc', '-module-cache-path', '/tmp/widget-swift-cache', '-swift-version', '5', str(swift), '-o', str(binary), '-framework', 'Cocoa', '-framework', 'Network', '-framework', 'UserNotifications', '-framework', 'WidgetKit'], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
