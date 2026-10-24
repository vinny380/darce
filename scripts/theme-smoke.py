#!/usr/bin/env python3
"""Build/run the actual Metal fixture; retain exact source and output identity."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
(root / 'artifacts').mkdir(exist_ok=True)
output = Path(tempfile.mkdtemp(prefix='theme-gpu-', dir=root / 'artifacts'))
sources = [root / 'Package.swift', Path(__file__).resolve(),
           root / 'Sources/BrowserTheme/ThemeRenderer.swift',
           root / 'Sources/ThemeRenderSmoke/main.swift']
def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
before = hashes()
command = ['swift', 'run', '--package-path', str(root), '--jobs', '2', 'ThemeRenderSmoke', str(output)]
started = time.monotonic()
record = {'command': command, 'source_before': before, 'timeout_seconds': 60}
for name, invocation in [('swift', ['swift', '--version']), ('system', ['sw_vers'])]:
    metadata = subprocess.run(invocation, capture_output=True, text=True, timeout=10)
    record[name] = {'exit': metadata.returncode, 'stdout': metadata.stdout, 'stderr': metadata.stderr}
try:
    run = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (output / 'build-and-run.stdout').write_text(run.stdout)
    (output / 'build-and-run.stderr').write_text(run.stderr)
    record['exit'] = run.returncode
except subprocess.TimeoutExpired as error:
    (output / 'build-and-run.stdout').write_bytes(error.stdout or b'')
    (output / 'build-and-run.stderr').write_bytes(error.stderr or b'')
    record.update(exit=None, error='Build/run exceeded 60 seconds; no retry')
record['elapsed_seconds'] = time.monotonic() - started
record['source_after'] = hashes()
record['source_unchanged'] = before == record['source_after']
result_path = output / 'result.json'
result = json.loads(result_path.read_text()) if result_path.exists() else {}
record['pass'] = record.get('exit') == 0 and record['source_unchanged'] and result.get('pass') is True
record['passed_checks'] = sum(c.get('pass') is True for c in result.get('checks', []))
record['total_checks'] = len(result.get('checks', []))
record['outputs'] = {p.name: {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                     for p in sorted(output.iterdir()) if p.is_file()}
(output / 'verification.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({'pass': record['pass'], 'checks': record['passed_checks'], 'directory': str(output)}))
raise SystemExit(0 if record['pass'] else 1)
