"""Compile the production parser against isolated quota fixtures (no account access)."""
import json
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[1] / 'AgentUsage.swift').read_text()
limit = source[source.index('struct Limit:'):source.index('struct Usage:')]
limit += source[source.index('func tailText('):source.index('enum OllamaLimits {')]
parser = source[source.index('enum CodexLimits {'):source.index('// MARK: - Helpers d’affichage') if '// MARK: - Helpers d’affichage' in source else source.index('// MARK: - Helpers d\'affichage')]
with tempfile.TemporaryDirectory(prefix='widget-quota-test-') as tmp:
    root = pathlib.Path(tmp)
    sessions = root / '.codex/sessions'
    sessions.mkdir(parents=True)
    def event(timestamp, primary, secondary=None, budget='codex'):
        return json.dumps({'timestamp': timestamp, 'payload': {'rate_limits': {
            'limit_id': budget, 'primary': primary, 'secondary': secondary, 'plan_type': 'plus'}}}).encode() + b'\n'
    short = {'used_percent': 30, 'window_minutes': 300, 'resets_at': 2000000300}
    week = {'used_percent': 19, 'window_minutes': 10080, 'resets_at': 2000600000}
    data = event('2033-05-18T03:33:20Z', short, week)
    data += event('2033-05-18T03:33:21Z', dict(short, used_percent=99), budget='codex_other_model')
    # Force the 1 MB tail to start on the second byte of a multibyte character.
    padding = b'x' * (1_000_000 - len(data) - 3)
    fixture = sessions / 'rollout-test.jsonl'
    fixture.write_bytes(b'prefix\xc3\xa9\n' + padding + b'\n' + data)
    assert fixture.read_bytes()[-1_000_000] == 0xa9
    # Codex app log, current format: lowercase headers, space after the colon.
    import sqlite3
    db = sqlite3.connect(root / 'app-log.sqlite')
    db.execute('CREATE TABLE logs (ts INTEGER, id INTEGER, feedback_log_body TEXT)')
    db.execute('INSERT INTO logs VALUES (2000000100, 1, ?)', ('{"x-codex-plan-type": "plus", "x-codex-primary-used-percent": "100", '
        '"x-codex-primary-window-minutes": "300", "x-codex-primary-reset-at": "2000010000", '
        '"x-codex-secondary-used-percent": "17", "x-codex-secondary-window-minutes": "10080"}',))
    db.commit(); db.close()
    parser = parser.replace('FileManager.default.homeDirectoryForCurrentUser', f'URL(fileURLWithPath: {json.dumps(tmp)})')
    assertions = '''
let s = CodexLimits.read(now: Date(timeIntervalSince1970: 2000000000))
assert(s.fiveHour?.remaining == 70, "5h account quota / UTF-8 tail")
assert(s.sevenDay?.remaining == 81, "weekly account quota")
assert(s.plan == "plus")
assert(s.asOf?.timeIntervalSince1970 == 2000000000, "ignore model-specific budget")
let expired = CodexLimits.read(now: Date(timeIntervalSince1970: 2000000400))
assert(expired.fiveHour?.remaining == 100)
assert(expired.fiveHour?.resetsAt == nil)
assert(expired.sevenDay?.remaining == 81)
try! FileManager.default.copyItem(atPath: home + "/app-log.sqlite", toPath: home + "/.codex/logs_2.sqlite")
let app = CodexLimits.read(now: Date(timeIntervalSince1970: 2000000200))
assert(app.fiveHour?.remaining == 0 && app.sevenDay?.remaining == 83, "lowercase app-log headers")
print("PASS: 5h + weekly, remaining %, budget filter, UTF-8 tail, expired reset, app-log headers")
'''
    swift = root / 'test.swift'
    swift.write_text('import Foundation\nlet home = ' + json.dumps(tmp) + '\n' + limit + parser + assertions)
    binary = root / 'test'
    subprocess.run(['swiftc', '-module-cache-path', str(root / 'cache'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
