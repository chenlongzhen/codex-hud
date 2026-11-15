#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then printf 'Usage: verify-claude-probe.sh <binary> <private-workdir>\n' >&2; exit 2; fi
root="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/python3 - "$1" "$2" "$root" <<'PY'
import json, os, pathlib, signal, stat, subprocess, sys, time
binary=pathlib.Path(sys.argv[1]).resolve(strict=True)
requested=pathlib.Path(sys.argv[2]).absolute()
work=requested.parent.resolve(strict=True)/requested.name
assert not requested.is_symlink() and work.parent.stat().st_uid==os.getuid() and not stat.S_IMODE(work.parent.stat().st_mode)&0o022
assert not work.exists() or (work.is_dir() and not any(work.iterdir()))
work.mkdir(mode=0o700,exist_ok=True)
assert not stat.S_IMODE(work.stat().st_mode)&0o077
root=pathlib.Path(sys.argv[3]); children=[]; groups=[]; checks={}
def check(name, value):
    assert value, name
    checks[name]=True
# Minimal native helper observes env/fds at exec, before Foundation/shell startup can add variables.
source=work/'fake.c'
source.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>
extern char **environ;
int main(int argc,char **argv){
 if(argc!=4||strcmp(argv[1],"--safe-mode")||strcmp(argv[2],"--strict-mcp-config")||strcmp(argv[3],"/usage"))return 9;
 char base[4096],path[8192],mode[64]={0}; snprintf(base,sizeof(base),"%s",argv[0]); char *slash=strrchr(base,'/');if(!slash)return 10;*slash=0;
 snprintf(path,sizeof(path),"%s/mode",base); FILE *f=fopen(path,"r");if(!f)return 11;fgets(mode,sizeof(mode),f);fclose(f);
 int extra=0;for(int fd=3;fd<256;fd++)if(fcntl(fd,F_GETFD)>=0)extra++;
 int tty=open("/dev/tty",O_RDWR);int hasTTY=tty>=0;if(tty>=0)close(tty);
 snprintf(path,sizeof(path),"%s/environment",base);f=fopen(path,"w");for(char **e=environ;*e;e++)fwrite(*e,1,strlen(*e)+1,f);fclose(f);
 if(!strcmp(mode,"hang")){signal(SIGTERM,SIG_IGN);signal(SIGHUP,SIG_IGN);}
 snprintf(path,sizeof(path),"%s/ready",base);f=fopen(path,"w");fprintf(f,"%d %d %d %d\n",getpid(),getpgrp(),hasTTY,extra);fclose(f);
 if(!strcmp(mode,"overflow")){for(int i=0;i<200000;i++)fputs("0123456789abcdef",stdout);fflush(stdout);}
 if(!strcmp(mode,"login")){puts("Not logged in. Please run /login");fflush(stdout);return 0;}
 if(!strcmp(mode,"hang")||!strcmp(mode,"crash")){
   pid_t child=fork();if(child==0){while(1)pause();}while(1)pause();
 }
 if(!strcmp(mode,"trust")||!strcmp(mode,"trust-wrong")){
   char cwd[4096];getcwd(cwd,sizeof(cwd));
   printf("Accessing workspace:\n%s\nQuick safety check: Do you trust this folder?\n❯ No, exit\nYes, I trust this folder\n",!strcmp(mode,"trust")?cwd:"/not-the-probe-directory");fflush(stdout);
   char input[128];if(!fgets(input,sizeof(input),stdin))return 12;
   snprintf(path,sizeof(path),"%s/keys",base);f=fopen(path,"w");fwrite(input,1,strlen(input),f);fclose(f);
   printf("\033[2J\033[H");
 }
 time_t now=time(NULL),five=now+3600,week=now+86400;struct tm t;char a[80],b[80];
 gmtime_r(&five,&t);strftime(a,sizeof(a),"%I:%M%p",&t);gmtime_r(&week,&t);strftime(b,sizeof(b),"%b %d at %I:%M%p",&t);
 printf("Current session\n8%% used\nResets %s (UTC)\nCurrent week (all models)\n23%% used\nResets %s (UTC)\nPer-model breakdown unavailable (rate limited until 11pm)\nApproximate\n13%% used\n",a,b);fflush(stdout);
 while(1)pause();
}
''')
exe=work/'fake-claude'
subprocess.run(['/usr/bin/clang','-O0',str(source),'-o',str(exe)],check=True,capture_output=True)
exe.chmod(0o700)
base=[str(binary),'--probe-claude-once','--claude-executable',str(exe),'--claude-snapshot-dir',str(work/'snap'),'--claude-probe-dir',str(work/'cwd')]
env=dict(os.environ,CLAUDECODE='injected',CLAUDE_CODE_FOO='injected',ANTHROPIC_API_KEY='synthetic-not-a-key')
def mode(name): (work/'mode').write_text(name)
def run(name, extra=('--dry-run',), timeout=40):
    mode(name); r=subprocess.run(base+list(extra),capture_output=True,env=env,timeout=timeout)
    assert not r.stderr, (name,'unexpected stderr')
    data=json.loads(r.stdout); return r,data
def live_group(pid):
    ps=subprocess.run(['/bin/ps','-axo','pid=,pgid=,stat='],capture_output=True,text=True,check=True)
    return [x for x in ps.stdout.splitlines() if len(x.split())>=3 and int(x.split()[1])==pid and not x.split()[2].startswith('Z')]
def wait_ready(p, previous):
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        assert p.poll() is None,'probe quit before ready'
        if (work/'ready').exists():
            fields=(work/'ready').read_text().split()
            if len(fields)==4 and int(fields[0])!=previous:return int(fields[0])
        time.sleep(.02)
    raise AssertionError('no readiness signal')
try:
    r,d=run('success')
    check('parsed_and_no_model_request_arguments',r.returncode==0 and d['status']=='success' and d['fiveHour']['usedPercentage']==8 and d['sevenDay']['usedPercentage']==23)
    check('dry_run_does_not_write_snapshot',not (work/'snap/snapshot.json').exists())
    fields=list(map(int,(work/'ready').read_text().split()))
    check('controlling_terminal_private_group_no_fds',fields[0]==fields[1] and fields[2:]==[1,0])
    keys={x.split(b'=',1)[0].decode() for x in (work/'environment').read_bytes().split(b'\0') if x}
    check('exact_environment_whitelist',keys=={'HOME','USER','LOGNAME','PATH','TERM','LANG','COLUMNS','LINES','DISABLE_AUTOUPDATER'})
    check('normal_no_descendants',not live_group(d['childPid']))
    r,d=run('success',extra=())
    snap=json.loads((work/'snap/snapshot.json').read_bytes())
    check('probe_schema2_no_fake_bridge',r.returncode==0 and snap['schema']==2 and 'bridgeSeenAt' not in snap and 'probedAt' in snap and 'confirmedAt' in snap['fiveHour'])
    check('per_model_limit_does_not_backoff',d['retryAfter'] is None)
    r,d=run('trust');check('trust_only_matching_private_directory',r.returncode==0 and (work/'keys').read_bytes()==b'\x1b[B\n')
    old=(work/'keys').stat().st_mtime_ns
    r,d=run('trust-wrong');check('wrong_trust_path_no_input',r.returncode==1 and d['status']=='trustFailed' and (work/'keys').stat().st_mtime_ns==old)
    r,d=run('login');check('login_requires_user',r.returncode==1 and d['status']=='loginRequired')
    r,d=run('overflow');check('bounded_output',r.returncode==1 and d['status']=='outputOverflow' and d['elapsedSeconds']<33)
    previous=int((work/'ready').read_text().split()[0]);mode('crash')
    p=subprocess.Popen(base+['--dry-run'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env);children.append(p)
    child=wait_ready(p,previous);groups.append(child)
    q=subprocess.run(base+['--dry-run'],capture_output=True,env=env,timeout=5)
    check('cross_process_single_flight',q.returncode==1 and json.loads(q.stdout)['status']=='busy')
    p.kill();p.communicate(timeout=5)
    deadline=time.monotonic()+3
    while live_group(child) and time.monotonic()<deadline:time.sleep(.05)
    check('parent_sigkill_hangup_cleans_group',not live_group(child))
    # Actual production 30s budget, not an injected shortened timeout.
    r,d=run('hang');timeout_elapsed=d['elapsedSeconds'];check('real_deadline_and_sigkill_escalation',r.returncode==1 and d['status']=='timeout' and 31.8<=timeout_elapsed<34 and d['exitStatus']==signal.SIGKILL and not live_group(d['childPid']))
    previous=int((work/'ready').read_text().split()[0]);mode('hang')
    p=subprocess.Popen(base+['--dry-run'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env);children.append(p)
    child=wait_ready(p,previous);groups.append(child)
    p.terminate();out,err=p.communicate(timeout=5);cancelled=json.loads(out)
    check('sigterm_cancels_and_reaps',p.returncode==1 and cancelled['status']=='cancelled' and not err and not live_group(child))
    (work/'cwd/unexpected').write_text('preserve')
    r,d=run('success');check('nonempty_cwd_refused',d['status']=='probeDirNotEmpty' and (work/'cwd/unexpected').read_text()=='preserve')
    exe.chmod(0o777);r,d=run('success');check('untrusted_executable_refused',d['status']=='untrustedExecutable')
    import re
    allowed={'AppServer.swift','ClaudeProbe.swift'}
    forbidden=[]
    for source in (root/'Sources').rglob('*.swift'):
        if source.name not in allowed and re.search(r'Process\(|posix_spawn\(|popen\(|execv\(|fork\(',source.read_text()):forbidden.append(str(source.relative_to(root)))
    check('process_creation_only_allowlisted_files',not forbidden)
    (work/'probe-check.json').write_text(json.dumps({'checks':checks,'realAccountUsed':False,'timeoutCaseElapsedSeconds':timeout_elapsed},indent=2)+'\n')
    print('PASS: claude probe %d checks'%len(checks))
finally:
    for p in children:
        if p.poll() is None:p.kill()
        p.wait(timeout=5)
    for pid in groups:
        if live_group(pid):
            try:os.killpg(pid,signal.SIGKILL)
            except ProcessLookupError:pass
PY
