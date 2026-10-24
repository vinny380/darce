#!/usr/bin/env python3
"""Compare the real semantic producer to fixed independent numeric expectations."""
import hashlib,json,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
(root/'artifacts').mkdir(exist_ok=True)
out=Path(tempfile.mkdtemp(prefix='semantic-numeric-',dir=root/'artifacts'))
files=[*sorted((root/'Sources/BrowserTheme').glob('*.swift')),root/'scripts/fixtures/SemanticPaletteSmoke.swift',root/'scripts/fixtures/semantic-color-oracles.json',Path(__file__).resolve()]
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
record={'before':hashes(),'steps':[]}
commands=[['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','BrowserTheme','-emit-module','-emit-module-path',str(out/'BrowserTheme.swiftmodule'),'-emit-library','-static',*map(str,sorted((root/'Sources/BrowserTheme').glob('*.swift'))),'-o',str(out/'libBrowserTheme.a')],
 ['xcrun','swiftc','-swift-version','5','-I',str(out),str(root/'scripts/fixtures/SemanticPaletteSmoke.swift'),str(out/'libBrowserTheme.a'),'-framework','AppKit','-framework','Metal','-framework','QuartzCore','-o',str(out/'SemanticPaletteSmoke')],
 [str(out/'SemanticPaletteSmoke'),str(root/'scripts/fixtures/semantic-color-oracles.json'),str(out/'result.json')]]
for i,command in enumerate(commands):
 r=subprocess.run(command,capture_output=True,text=True,timeout=60)
 (out/f'{i}.stdout').write_text(r.stdout);(out/f'{i}.stderr').write_text(r.stderr)
 record['steps'].append({'command':command,'exit_code':r.returncode})
 if r.returncode:break
record['after']=hashes()
result=json.loads((out/'result.json').read_text()) if (out/'result.json').exists() else {}
record['passed']=len(record['steps'])==3 and all(x['exit_code']==0 for x in record['steps']) and record['before']==record['after'] and result.get('passed') is True
(out/'verification.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':record['passed'],'directory':str(out),'checks':len(result.get('checks',[]))}))
raise SystemExit(0 if record['passed'] else 1)
