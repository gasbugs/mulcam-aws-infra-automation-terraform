#!/usr/bin/env bash
# workshop-management 소스를 site-packages에 동기화한다.
# PostToolUse hook에서 .py 파일 수정 시 자동 호출된다.
set -e

SITE=$(python3 -c "
import site, os
for p in site.getsitepackages() + [site.getusersitepackages()]:
    if 'site-packages' in p and os.path.isdir(os.path.join(p, 'commands')):
        print(p)
        break
")

[ -z "$SITE" ] && exit 0

SRC="/Users/gasbugs/mulcam-aws-infra-automation-terraform/workshop-management"

cp "$SRC/awsw.py" "$SITE/awsw.py"
for dir in commands utils; do
  for f in "$SRC/$dir"/*.py; do
    [ -f "$f" ] && cp "$f" "$SITE/$dir/$(basename "$f")"
  done
done
mkdir -p "$SITE/commands/cleaners"
cp "$SRC/commands/cleaners/"*.py "$SITE/commands/cleaners/"
