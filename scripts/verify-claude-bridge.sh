#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then printf 'Usage: verify-claude-bridge.sh <binary> <private-workdir>\n' >&2; exit 2; fi
root="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/python3 - "$1" "$2" "$root/.build/debug/HUDCoreChecks" <<'PY'
import concurrent.futures,fcntl,hashlib,json,os,pathlib,selectors,signal,stat,subprocess,sys,time
binary=pathlib.Path(sys.argv[1]).resolve(strict=True)
requested=pathlib.Path(sys.argv[2]).absolute()
work=requested.parent.resolve(strict=True)/requested.name
assert not requested.is_symlink() and work.parent.stat().st_uid==os.getuid() and not stat.S_IMODE(work.parent.stat().st_mode)&0o022
assert not work.exists() or (work.is_dir() and not any(work.iterdir()))
work.mkdir(mode=0o700,exist_ok=True)
assert not stat.S_IMODE(work.stat().st_mode)&0o077
helper=pathlib.Path(sys.argv[3]).resolve(strict=True)
checks={}; times=[]; children=[]
now=int(time.time())
request={'session_id':'s-secret','cwd':'s-secret','session_name':'s-secret','workspace':{'name':'s-secret'},'rate_limits':{'five_hour':{'used_percentage':42,'resets_at':now+3600},'seven_day':{'used_percentage':23,'resets_at':now+86400}}}
raw=json.dumps(request).encode()
snap=work/'snap'
def check(name,value):
    assert value,name
    checks[name]=True
def run(data=raw,directory=snap,extra=()):
    return subprocess.run([str(binary),'--claude-statusline-bridge','--claude-snapshot-dir',str(directory),*extra],input=data,capture_output=True,timeout=3)
def parsed(directory=snap):
    s=json.loads((directory/'snapshot.json').read_bytes())
    assert set(s)<={'schema','bridgeSeenAt','probedAt','fiveHour','sevenDay'} and s['schema']==2
    for k in ('fiveHour','sevenDay'):
        if k in s: assert {'usedPercentage','resetsAt','changedAt'} <= set(s[k]) <= {'usedPercentage','resetsAt','changedAt','confirmedAt'}
    return s
def fingerprint(directory=snap):return hashlib.sha256((directory/'snapshot.json').read_bytes()).digest()
def await_ready(p):
    selector=selectors.DefaultSelector();selector.register(p.stdout,selectors.EVENT_READ)
    assert selector.select(5),'worker did not signal ready'
    assert p.stdout.readline()==b'LOCKED\n','worker had not actually acquired lock'
    selector.close()
def tracked(p):children.append(p);return p
try:
    r=run();check('valid_stdout_exit_stderr',r.returncode==0 and r.stdout=='5h 58% · W 77%\n'.encode() and not r.stderr)
    s=parsed();check('whitelist_no_private_fields',set(s)=={'schema','bridgeSeenAt','fiveHour','sevenDay'} and b'secret' not in (snap/'snapshot.json').read_bytes())
    check('private_modes',stat.S_IMODE(snap.stat().st_mode)==0o700 and all(stat.S_IMODE((snap/x).stat().st_mode)==0o600 for x in ('snapshot.json','.lock')))
    r=run(extra=('--silent',));check('silent',r.returncode==0 and not r.stdout and not r.stderr)
    digest=fingerprint()
    for label,data in [('malformed',b'not json'),('array',b'[]'),('oversize',b' '*262145),('nan',b'{"rate_limits":{"five_hour":{"used_percentage":NaN}}}')]:
        r=run(data);check(label,r.returncode==0 and not r.stdout and not r.stderr and fingerprint()==digest)
    r=run(b'{}');empty=parsed();check('empty_preserves_windows',r.returncode==0 and r.stdout==b'\n' and empty['fiveHour']==s['fiveHour'] and empty['sevenDay']==s['sevenDay'])
    r=run(json.dumps({'rate_limits':{'seven_day':{'used_percentage':24,'resets_at':now+86400}}}).encode())
    check('partial_merge',parsed()['fiveHour']==s['fiveHour'] and parsed()['sevenDay']['usedPercentage']==24)
    for invalid in ['42',True,None,101,-1]:
        r=run(json.dumps({'rate_limits':{'five_hour':{'used_percentage':invalid,'resets_at':now+3600},'seven_day':{'used_percentage':25,'resets_at':now+86400}}}).encode())
        check('bad_window_'+repr(invalid),r.returncode==0 and r.stdout=='W 75%\n'.encode() and parsed()['fiveHour']['usedPercentage']==42)
    digest=fingerprint()
    producer=tracked(subprocess.Popen(['/bin/sleep','10'],stdout=subprocess.PIPE))
    start=time.monotonic()
    p=tracked(subprocess.Popen([str(binary),'--claude-statusline-bridge','--claude-snapshot-dir',str(snap)],stdin=producer.stdout,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
    producer.stdout.close()
    out,err=p.communicate(timeout=2.5);elapsed=time.monotonic()-start
    producer.kill();producer.wait()
    check('no_eof_bridge_pid_deadline',p.returncode==0 and elapsed<2.5 and not out and not err and fingerprint()==digest)
    checks['producer_measured_separately_and_reaped']=True
    victim=work/'victim';victim.write_bytes(b'untouched')
    bad=work/'symlink';bad.mkdir(mode=0o700);(bad/'snapshot.json').symlink_to(victim)
    r=run(directory=bad);check('target_symlink_refused_but_stdout_valid',r.returncode==0 and r.stdout=='5h 58% · W 77%\n'.encode() and (bad/'snapshot.json').is_symlink() and victim.read_bytes()==b'untouched')
    denied=work/'denied';denied.mkdir(mode=0o755);denied.chmod(0o755)
    r=run(directory=denied);check('permissions_refused_but_stdout_valid',r.returncode==0 and r.stdout=='5h 58% · W 77%\n'.encode() and not (denied/'snapshot.json').exists())
    worker=tracked(subprocess.Popen([str(helper),'--test-lock-worker',str(snap)],stdout=subprocess.PIPE,stderr=subprocess.PIPE))
    await_ready(worker)
    start=time.monotonic();r=run();delay=time.monotonic()-start
    check('lock_busy_still_outputs',r.returncode==0 and r.stdout=='5h 58% · W 77%\n'.encode() and not r.stderr and 0.29<=delay<1)
    worker.kill();worker.communicate(timeout=3)
    r=run();check('sigkill_releases_acquired_lock',r.returncode==0 and parsed()['fiveHour']['usedPercentage']==42)
    p=tracked(subprocess.Popen([str(binary),'--claude-statusline-bridge','--claude-snapshot-dir',str(snap)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
    p.terminate();p.communicate(timeout=3);check('external_sigterm_not_promised_zero',p.returncode==-signal.SIGTERM)
    p=tracked(subprocess.Popen([str(binary),'--claude-statusline-bridge','--claude-snapshot-dir',str(snap)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
    p.stdout.close();p.stdin.write(raw);p.stdin.close();p.wait(timeout=3)
    check('closed_stdout_epipe',p.returncode==0 and not p.stderr.read())
    # Establish a valid complete baseline before concurrent readers/writers.
    run();parsed()
    def writer(index):
        window='five_hour' if index%2 else 'seven_day'
        r=run(json.dumps({'rate_limits':{window:request['rate_limits'][window]}}).encode())
        return r.returncode==0 and not r.stderr
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
        futures=[pool.submit(writer,i) for i in range(20)]
        for _ in range(200):parsed()
        check('concurrent_writers_20_readers_200',all(f.result() for f in futures) and all(k in parsed() for k in ('fiveHour','sevenDay')))
    for _ in range(20):
        start=time.monotonic();r=run();times.append(time.monotonic()-start)
        assert r.returncode==0 and not r.stderr
    check('twenty_launches_under_one_second_each',max(times)<1)
    # Generate the actual pure-text wrapper using the debug test executable, not a copied template.
    fake=work/'fake-bridge';fake.write_text('#!/bin/sh\n/bin/cat > '+str(work/'fake-input')+'\nexit 7\n');fake.chmod(0o700)
    wrapper=work/'wrapper.sh'
    original="/bin/cat > '"+str(work/'orig-input')+"'; printf ORIG; exit 3"
    subprocess.run([str(helper),'--export-wrapper',str(wrapper),str(fake),json.dumps(original),'/bin/bash'],check=True,timeout=3)
    large=b'x'*524288+b"' $ \\ \n\n"
    r=subprocess.run(['/bin/sh',str(wrapper)],input=large,capture_output=True,timeout=5)
    check('wrapper_large_input_preserved',r.returncode==3 and r.stdout==b'ORIG' and not r.stderr and (work/'fake-input').read_bytes()==large and (work/'orig-input').read_bytes()==large)
    p=tracked(subprocess.Popen(['/bin/sh',str(wrapper)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True))
    try:
        p.wait(timeout=2.3)
        raise AssertionError('wrapper collection incorrectly bounded by bridge budget')
    except subprocess.TimeoutExpired: pass
    os.killpg(p.pid,signal.SIGTERM);p.communicate(timeout=3)
    check('wrapper_no_eof_collection_and_group_cancel',p.returncode in (143,-signal.SIGTERM))
    ready=work/'original-ready'
    original="printf ready > '"+str(ready)+"'; exec /bin/sleep 30"
    subprocess.run([str(helper),'--export-wrapper',str(wrapper),str(fake),json.dumps(original),'/bin/zsh'],check=True,timeout=3)
    p=tracked(subprocess.Popen(['/bin/sh',str(wrapper)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True))
    p.stdin.close()
    # A pipe readiness signal avoids an arbitrary sleep or an unacquired-worker assumption.
    deadline=time.monotonic()+3
    while not ready.exists():
        assert p.poll() is None and time.monotonic()<deadline
        selectors.DefaultSelector().select(0.01)
    os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=3)
    ps=subprocess.run(['/bin/ps','-axo','pid=,pgid=,stat='],capture_output=True,text=True,check=True)
    active=[line for line in ps.stdout.splitlines() if len(line.split())>=3 and int(line.split()[1])==p.pid and not line.split()[2].startswith('Z')]
    check('wrapper_original_group_sigterm',not active)
    result={'checks':checks,'bridgeNoEOFSeconds':elapsed,'launchSeconds':times,'launchMinSeconds':min(times),'launchMedianSeconds':sorted(times)[len(times)//2],'launchMaxSeconds':max(times),'realClaudeCancellation':'unverified','timingScope':'whole process launch; watchdog itself begins at bridge main, wrapper collection excluded'}
    (work/'bridge-check.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS: claude bridge %d checks'%len(checks))
    print('launch seconds min/median/max: %.6f / %.6f / %.6f'%(min(times),sorted(times)[10],max(times)))
finally:
    for p in children:
        if p.poll() is None:
            try:
                if p.args[:1]==['/bin/sh']:os.killpg(p.pid,signal.SIGKILL)
                else:p.kill()
            except ProcessLookupError:pass
        try:p.wait(timeout=3)
        except subprocess.TimeoutExpired:pass
PY
