"""Check normal/compact/summary/submenu modes on isolated production menu data."""
import pathlib
import subprocess
import tempfile
source = (pathlib.Path(__file__).resolve().parents[1] / 'AgentUsage.swift').read_text()
source = source[:source.index('// `--once` :')]
source = source.replace('UserDefaults.standard.string(forKey: "detailedMenuStyle")', 'TestStyle.value')
source = source.replace('static func visible(_ id: String) -> Bool { !hidden.contains(id) }', 'static func visible(_ id: String) -> Bool { true }')
source += r'''
enum TestStyle { static var value: String? = "normal" }
let app = NSApplication.shared
let delegate = AppDelegate()
var usage = Usage()
usage.fiveHour = Limit(utilization: 10, resetsAt: Date().addingTimeInterval(3600))
usage.sevenDay = Limit(utilization: 70, resetsAt: Date().addingTimeInterval(86400))
usage.todayCost = 4
usage.codexFiveHour = Limit(utilization: 20, resetsAt: Date().addingTimeInterval(7200))
usage.codexSevenDay = Limit(utilization: 40, resetsAt: nil)
usage.ollamaWeekly = Limit(utilization: 70.6, resetsAt: nil)
usage.ollamaSessionInactive = true
func texts() -> [String] { delegate.menu.items.compactMap { ($0.view?.subviews.first as? NSTextField)?.stringValue } }
delegate.rebuildMenu(usage: usage)
let normalCount = delegate.menu.items.count
TestStyle.value = "compact"
delegate.rebuildMenu(usage: usage)
assert(delegate.menu.items.count < normalCount, "balanced mode puts resets on quota rows")
assert(texts().contains { $0.contains("↻") })
TestStyle.value = "ultra"
delegate.rebuildMenu(usage: usage)
assert(delegate.menu.items.count < normalCount)
assert(texts().contains { $0.contains("Claude") && $0.contains("90%") && $0.contains("30%") })
assert(texts().contains { $0.contains("Ollama") && $0.contains("29%") && $0.contains("inactive") })
TestStyle.value = "folded"
delegate.rebuildMenu(usage: usage)
let claude = delegate.menu.items.first { $0.title.hasPrefix("Claude") }
assert(claude?.submenu?.items.isEmpty == false)
assert(claude!.title.contains("90%"))
TestStyle.value = "normal"
delegate.rebuildMenu(usage: usage)
assert(delegate.menu.items.count == normalCount)
print("PASS: all menu versions preserve quotas, compact resets and expandable details")
'''
with tempfile.TemporaryDirectory(prefix='widget-menu-styles-test-') as tmp:
    root = pathlib.Path(tmp); path = root / 'main.swift'; path.write_text(source)
    binary = root / 'test'
    subprocess.run(['swiftc', '-module-cache-path', '/tmp/widget-swift-cache', '-swift-version', '5', str(path), '-o', str(binary), '-framework', 'Cocoa', '-framework', 'Network', '-framework', 'UserNotifications', '-framework', 'WidgetKit'], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
