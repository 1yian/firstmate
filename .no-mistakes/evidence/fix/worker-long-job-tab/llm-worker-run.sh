#!/usr/bin/env bash
EV=/Users/yian/.no-mistakes/evidence/01M52QSZR3NKSD7420Z373TPSD
cd /tmp/fm-jobtab-wd/llm || exit 1
python3 - <<'PY' > "$EV/llm-worker-transcript.txt" 2>&1
import subprocess
ev="/Users/yian/.no-mistakes/evidence/01M52QSZR3NKSD7420Z373TPSD"
p=open(ev+"/llm-worker-prompt.txt").read()
try:
    r=subprocess.run(["claude","-p",p,"--allowedTools","Bash","--output-format","stream-json","--verbose"],capture_output=True,text=True,timeout=420)
    print(r.stdout); print(r.stderr); print("EXIT",r.returncode)
except subprocess.TimeoutExpired as e:
    print("TIMEOUT", e.stdout)
PY
echo done > /tmp/fm-jobtab-wd/llm/runner.done
