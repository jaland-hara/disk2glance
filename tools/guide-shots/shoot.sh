#!/bin/bash
# Re-take the guide screenshots from the d2g UI in this repository on recorded, neutralized data.
# Usage: tools/guide-shots/shoot.sh            (macOS, Google Chrome)
set -e
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../.." && pwd); OUT=$R/docs/img/guide; PORT=8790
python3 "$H/mock.py" "$R/server/d2g/static" "$H/data" $PORT & MOCK=$!; trap 'kill $MOCK' EXIT; sleep 1
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
while read -r n u h; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,$h --force-device-scale-factor=1 \
    --virtual-time-budget=6000 --user-data-dir=/tmp/d2g-shot-profile --screenshot="$OUT/$n.png" "http://127.0.0.1:$PORT$u" >/dev/null 2>&1
  echo "$n"
done <<'L'
01-setup-code /setup?shot=code 700
02-setup-admin /setup?shot=admin 900
03-setup-cloud /setup?shot=cloud 1000
04-setup-place /setup?shot=place 700
05-setup-rx /setup?shot=rx 900
06-setup-access /setup?shot=access 900
07-setup-apply /setup?shot=apply 900
08-setup-done /setup?shot=done 700
09-login /login 600
11-agent-add-form /?scene=01-empty&tab=agents&shot=addagent-form 700
12-agent-add-command /?scene=01-empty&tab=agents&shot=addagent 800
13-agents /?scene=02-agent&tab=agents 600
14-job-new /?scene=02-agent&tab=jobs&shot=newjob 800
15-jobs-receiving /?scene=03-receiving&tab=jobs 500
16-overview /?scene=03-receiving&tab=overview 600
17-jobs-synced /?scene=04-synced&tab=jobs 500
18-finish /?scene=04-synced&tab=jobs&shot=finish 900
19-log /?scene=05-finished&tab=log&shot=tasklog 900
20-jobs-finished /?scene=05-finished&tab=jobs 500
22-targets /?scene=05-finished&tab=targets 600
23-target-add /?scene=05-finished&tab=targets&shot=addtarget 900
L
