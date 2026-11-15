#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 ]]; then printf 'Usage: package.sh [private-temporary-output-directory]\n' >&2; exit 2; fi
requested="${1:-$(mktemp -d)/codex-hud-release}"
# Resolve and validate the exact output before any writes or build-script inode replacement.
out="$(/usr/bin/python3 - "$requested" <<'PY'
import os, pathlib, stat, sys, tempfile
p = pathlib.Path(sys.argv[1]).expanduser().absolute()
try:
    parent = p.parent.resolve(strict=True)
    resolved = parent / p.name
    temporary = pathlib.Path(tempfile.gettempdir()).resolve(strict=True)
    application_names = [pathlib.Path('/Applications'), pathlib.Path.home() / 'Applications']
    applications = application_names + [a.resolve(strict=False) for a in application_names]
    if p.is_symlink() or any(a == p or a in p.parents or a == resolved or a in resolved.parents for a in applications): raise ValueError('installation destination refused')
    if temporary not in resolved.parents: raise ValueError('this candidate must be built inside the private temporary area')
    info = parent.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077: raise ValueError('output parent must be user-owned and private')
    if resolved.exists() and (not resolved.is_dir() or any(resolved.iterdir())): raise ValueError('output must be absent or an empty directory')
    if resolved.exists():
        info = resolved.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077: raise ValueError('existing output must be private; no chmod applied')
    print(resolved)
except Exception as e:
    print('Unsafe output: ' + str(e), file=sys.stderr)
    sys.exit(2)
PY
)" || exit 2
umask 077
mkdir -p "$out"
stage="$out/stage"
mkdir "$stage"
"$root/scripts/build.sh" "$stage/Codex HUD.app"
bin="$stage/Codex HUD.app/Contents/MacOS/CodexHUD"
test "$(lipo -archs "$bin")" = arm64
test "$(plutil -extract LSMinimumSystemVersion raw "$stage/Codex HUD.app/Contents/Info.plist")" = 13.0
codesign --verify --strict "$stage/Codex HUD.app"
otool -l "$bin" > "$out/macho-load-commands.txt"
otool -L "$bin" > "$out/macho-dependencies.txt"
/usr/bin/python3 - "$out" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
load=(p/'macho-load-commands.txt').read_text()
minimum=re.findall(r'\bminos\s+([\d.]+)',load)
assert minimum == ['13.0'], ('Mach-O minimum OS',minimum)
lines=(p/'macho-dependencies.txt').read_text().splitlines()[1:]
deps=[line.strip().split(' (',1)[0] for line in lines]
assert deps and all(d.startswith(('/System/Library/','/usr/lib/')) for d in deps), ('non-system dynamic dependency',deps)
PY
cp "$root/docs/quickstart.zh-CN.md" "$stage/快速指南.md"
cp "$root/LICENSE" "$stage/LICENSE"
ditto -c -k --sequesterRsrc "$stage" "$out/CodexHUD-macOS-arm64.zip"
(cd "$out" && shasum -a 256 CodexHUD-macOS-arm64.zip > CodexHUD-macOS-arm64.zip.sha256 && shasum -a 256 -c CodexHUD-macOS-arm64.zip.sha256)
mkdir "$out/verify"
ditto -x -k "$out/CodexHUD-macOS-arm64.zip" "$out/verify"
codesign --verify --strict "$out/verify/Codex HUD.app"
plutil -lint "$out/verify/Codex HUD.app/Contents/Info.plist"
/usr/bin/python3 - "$out" "$root/LICENSE" <<'PY'
import hashlib,json,os,pathlib,stat,subprocess,sys,time
p=pathlib.Path(sys.argv[1]); v=p/'verify'
assert (v/'LICENSE').read_bytes()==pathlib.Path(sys.argv[2]).read_bytes()
assert (v/'快速指南.md').stat().st_size>0
now=int(time.time())
request={'cwd':'synthetic-secret','rate_limits':{'five_hour':{'used_percentage':42,'resets_at':now+3600},'seven_day':{'used_percentage':23,'resets_at':now+86400}}}
r=subprocess.run([str(v/'Codex HUD.app/Contents/MacOS/CodexHUD'),'--claude-statusline-bridge','--claude-snapshot-dir',str(v/'snap')],input=json.dumps(request).encode(),capture_output=True,timeout=3)
assert r.returncode==0 and r.stdout=='5h 58% · W 77%\n'.encode() and not r.stderr
s=json.loads((v/'snap/snapshot.json').read_bytes())
assert s['schema']==2 and set(s)=={'schema','bridgeSeenAt','fiveHour','sevenDay'} and s['fiveHour']['usedPercentage']==42
assert 'secret' not in json.dumps(s)
assert stat.S_IMODE((v/'snap/snapshot.json').stat().st_mode)==0o600
result={'archiveSelfCheck':True,'licenseIncluded':True,'syntheticBridgePassed':True,'architecture':'arm64','plistMinimumOS':'13.0','machOMinimumOS':'13.0','dynamicDependencies':'system-only','signature':'ad-hoc; not notarized','sha256':hashlib.sha256((p/'CodexHUD-macOS-arm64.zip').read_bytes()).hexdigest()}
(p/'package-check.json').write_text(json.dumps(result,indent=2)+'\n')
PY
printf 'PASS: local package self-check\nZip: %s\nSHA-256: %s\nEvidence: %s\n' "$out/CodexHUD-macOS-arm64.zip" "$out/CodexHUD-macOS-arm64.zip.sha256" "$out/package-check.json"
