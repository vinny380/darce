#!/usr/bin/env python3
"""Run a dedicated owned NSWindow fixture, retaining same-drawable capture evidence."""
import hashlib,json,plistlib,shutil,subprocess,tempfile,time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
out=Path(tempfile.mkdtemp(prefix='theme-mounted-',dir=root/'artifacts'))
files=[root/'Package.swift',Path(__file__).resolve(),root/'Sources/ThemeMountedSmoke/main.swift',*sorted((root/'Sources/BrowserTheme').glob('*.swift'))]
def hashes(): return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
record={'source_before':hashes(),'steps':[]}
def run(args,name,timeout=60):
    start=time.monotonic()
    result=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
    (out/(name+'.stdout')).write_text(result.stdout);(out/(name+'.stderr')).write_text(result.stderr)
    record['steps'].append({'name':name,'command':args,'exit':result.returncode,'seconds':time.monotonic()-start})
    if result.returncode: raise RuntimeError(name+' failed')
    return result.stdout
try:
    run(['swift','build','--package-path',str(root),'--jobs','2','--product','ThemeMountedSmoke'],'build')
    binary=Path(run(['swift','build','--package-path',str(root),'--show-bin-path'],'bin-path').strip())/'ThemeMountedSmoke'
    app=out/'Theme Verification.app';mac=app/'Contents/MacOS';mac.mkdir(parents=True)
    shutil.copy2(binary,mac/'ThemeMountedSmoke')
    with (app/'Contents/Info.plist').open('wb') as file:
        plistlib.dump({'CFBundleIdentifier':'io.github.vinny380.darce.theme-verification','CFBundleName':'Theme Verification',
                      'CFBundleExecutable':'ThemeMountedSmoke','CFBundlePackageType':'APPL','LSUIElement':True,
                      'NSHighResolutionCapable':True,'LSMinimumSystemVersion':'14.0'},file)
    run(['codesign','--force','--sign','-',str(app)],'sign')
    run(['codesign','--verify','--strict',str(app)],'verify-sign')
    run([str(mac/'ThemeMountedSmoke'),str(out)],'fixture',timeout=55)
    record['binary_sha256']=hashlib.sha256((mac/'ThemeMountedSmoke').read_bytes()).hexdigest()
except Exception as error: record['error']=str(error)
record['source_after']=hashes()
result=json.loads((out/'result.json').read_text()) if (out/'result.json').exists() else {}
record['pass']='error' not in record and record['source_before']==record['source_after'] and result.get('pass') is True
record['outputs']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.iterdir()) if p.is_file()}
(out/'verification.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'pass':record['pass'],'directory':str(out),'error':record.get('error')}))
raise SystemExit(0 if record['pass'] else 1)
