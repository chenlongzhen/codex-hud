#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then printf 'Usage: verify-claude-fixtures.sh <binary> <private-workdir>\n' >&2; exit 2; fi
exec /usr/bin/python3 - "$1" "$2" <<'PY'
import json,os,pathlib,stat,struct,subprocess,sys,time
binary=pathlib.Path(sys.argv[1]).resolve(strict=True)
requested=pathlib.Path(sys.argv[2]).absolute()
work=requested.parent.resolve(strict=True)/requested.name
assert not requested.is_symlink() and work.parent.stat().st_uid==os.getuid() and not stat.S_IMODE(work.parent.stat().st_mode)&0o022
assert not work.exists() or (work.is_dir() and not any(work.iterdir()))
work.mkdir(mode=0o700,exist_ok=True)
assert not stat.S_IMODE(work.stat().st_mode)&0o077
now=int(time.time()); checks={}
def bridge(folder,limits):
    result=subprocess.run([str(binary),'--claude-statusline-bridge','--claude-snapshot-dir',str(folder)],input=json.dumps({'cwd':'synthetic-secret','rate_limits':limits}).encode(),capture_output=True,timeout=3)
    assert result.returncode==0 and not result.stderr
    return folder
def fixture(name,folder,t):
    out=work/name
    result=subprocess.run([str(binary),'--check-claude',str(out),'--claude-snapshot-dir',str(folder),'--now',str(t)],capture_output=True,timeout=15)
    assert result.returncode==0,(name,result.returncode,result.stdout,result.stderr)
    state=json.loads(result.stdout)
    assert state==json.loads((out/'claude-state.json').read_text())
    assert isinstance(state['fiveHour'],dict) and 'fiveHour.state' not in state
    geometry=json.loads((out/'render-check.json').read_text())
    assert geometry['exact340pt'] and geometry['exactTabSize'] and geometry['logicalWidth']==340
    assert geometry['pixelWidth']==round(340*geometry['backingScale'])
    for image in ['expanded.png','edge-tab.png']:assert (out/image).stat().st_size>0
    return state,geometry
limits={'five_hour':{'used_percentage':100,'resets_at':now+3600},'seven_day':{'used_percentage':23,'resets_at':now+86400}}
folder=bridge(work/'snapshot',limits)
s,g=fixture('now',folder,now)
assert s['sevenDay']['state']=='observed' and s['tabClaudeText']=='77%' and s['fiveHourExhaustedHint']
checks['observed_weekly_and_independent_5h_exhaustion']=True
scale=g['backingScale']
s,_=fixture('stale',folder,now+960)
assert s['sevenDay']['state']=='stale' and s['fiveHour']['state']=='stale'
checks['unchanged_16m_stale']=True
s,_=fixture('passed',folder,now+3601)
assert s['fiveHour']['state']=='passed' and s['fiveHour']['remaining']=='—' and s['sevenDay']['state']=='stale'
checks['passed_retained_not_full']=True
bridge(folder,{})
s,_=fixture('empty-after-reset',folder,now+3601)
assert s['fiveHour']['state']=='passed'
checks['empty_does_not_erase_expiry_evidence']=True
s,_=fixture('absent',work/'absent-snapshot',now)
assert s['overall']=='noSnapshot' and s['tabClaudeText']=='—'
checks['absent']=True
waiting=bridge(work/'waiting-snapshot',{})
s,_=fixture('waiting',waiting,now)
assert s['overall']=='waiting'
checks['waiting']=True
only5=bridge(work/'only5-snapshot',{'five_hour':limits['five_hour']})
s,_=fixture('only5',only5,now)
assert s['sevenDay']['state']=='missing' and s['tabClaudeText']=='—' and s['fiveHourExhaustedHint']
checks['only_five_hour_never_substitutes_weekly']=True
(folder/'snapshot.json').write_bytes(b'{broken')
s,_=fixture('corrupt',folder,now)
assert s['overall']=='failed' and s['tabClaudeText']=='—' and s['fiveHour']['remaining']=='—'
checks['corrupt_clears_numbers_and_reports_failure']=True
for invalid in ['9223372036854775807','not-time']:
    result=subprocess.run([str(binary),'--check-claude',str(work/'bad-params'),'--claude-snapshot-dir',str(folder),'--now',invalid],capture_output=True,timeout=5)
    assert result.returncode==2
for conflicting in [['--diagnose','--check-claude'],['--demo','--check-window']]:
    result=subprocess.run([str(binary),*conflicting],capture_output=True,timeout=3)
    assert result.returncode==2 and not result.stdout
checks['invalid_check_arguments']=True
result=subprocess.run([str(binary),'--check-window',str(work/'window')],capture_output=True,timeout=25)
assert result.returncode==0,(result.stdout,result.stderr)
window=json.loads(result.stdout)
assert all(window['checks'].values())
(work/'window.json').write_bytes(result.stdout)
checks['release_native_window_checks']=len(window['checks'])
result=subprocess.run([str(binary),'--demo',str(work/'demo')],capture_output=True,timeout=15)
assert result.returncode==0,(result.stdout,result.stderr)
for image in ['overview','tokens','tasks','edge-tab','settings']:
    data=(work/'demo'/(image+'.png')).read_bytes()
    assert data[:8]==b'\x89PNG\r\n\x1a\n'
    width,height=struct.unpack('>II',data[16:24]);assert width>0 and height>0
    if image in ['overview','tokens','tasks']:assert width==round(340*scale),(image,width,scale)
    if image=='edge-tab':assert (width,height)==(round(46*scale),round(166*scale)),(width,height,scale)
checks['five_demo_renders_exact_width_and_dual_size']=True
(work/'fixture-check.json').write_text(json.dumps({'checks':checks,'fixtureNow':now,'backingScale':scale},indent=2)+'\n')
print('PASS: release fixture %d checks, %d native checks, five demo renders'%(len(checks),len(window['checks'])))
PY
