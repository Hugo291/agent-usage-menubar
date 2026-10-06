"""Compile the production parser against isolated quota fixtures (no account access)."""
import json
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[1] / 'ClaudeUsage.swift').read_text()
limit = source[source.index('struct Limit:'):source.index('struct Usage:')]
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
print("PASS: 5h + weekly, remaining %, budget filter, UTF-8 tail, expired reset")
'''
    swift = root / 'test.swift'
    swift.write_text('import Foundation\n' + limit + parser + assertions)
    binary = root / 'test'
    subprocess.run(['swiftc', '-module-cache-path', str(root / 'cache'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
