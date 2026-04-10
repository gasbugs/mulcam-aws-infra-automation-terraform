# awsw 패키지 배포 (site-packages 동기화)

로컬 소스 파일을 설치된 `awsw` 패키지 디렉터리에 동기화합니다.

다음 bash 명령을 실행하세요:

```bash
set -e

# site-packages 내 awsw 설치 경로 탐색
SITE=$(python3 -c "
import site, os
for p in site.getsitepackages() + [site.getusersitepackages()]:
    if 'site-packages' in p and os.path.isdir(os.path.join(p, 'commands')):
        print(p)
        break
")

if [ -z "$SITE" ]; then
  echo "오류: awsw 패키지 경로를 찾을 수 없습니다. 먼저 pip install -e . 를 실행하세요."
  exit 1
fi

SRC="$(cd "$(dirname "$0")/../../../.." && pwd)"
echo "소스: $SRC"
echo "대상: $SITE"

# 메인 진입점 및 서브디렉터리 동기화
cp "$SRC/awsw.py" "$SITE/awsw.py"
for dir in commands utils; do
  for f in "$SRC/$dir"/*.py; do
    [ -f "$f" ] && cp "$f" "$SITE/$dir/$(basename "$f")"
  done
done

# cleaners/ 서브패키지 동기화
mkdir -p "$SITE/commands/cleaners"
cp "$SRC/commands/cleaners/"*.py "$SITE/commands/cleaners/"

echo "동기화 완료"

# 설치 확인
python3 -c "from commands import clean, audit; from commands.cleaners import iam, compute, network, storage, database, misc; print('검증 완료: 전체 모듈 로드 성공')"
```
