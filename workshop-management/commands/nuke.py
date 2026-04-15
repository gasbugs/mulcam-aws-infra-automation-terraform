# =============================================================================
# commands/nuke.py
# awsw nuke — aws-nuke 바이너리를 통한 계정 전체 리소스 일괄 삭제
#
# audit + clean 의 기능을 aws-nuke 로 대체하는 명령이다.
# 기본값은 dry-run(삭제 없이 대상 목록만 출력)이며,
# --no-dry-run 플래그를 전달해야 실제로 삭제된다.
#
# 모든 계정을 병렬로 실행하고 프로그레스바와 요약 결과만 출력한다.
# 상세 로그는 --log-dir 로 지정한 디렉터리에 계정별로 저장된다.
#
# 의존 도구: aws-nuke (ekristen/aws-nuke v3)
#   설치: brew install aws-nuke
#   또는: https://github.com/ekristen/aws-nuke/releases
# =============================================================================
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from functools import partial
from pathlib import Path

import click
import yaml
from botocore.exceptions import ClientError

from utils.constants import EXPECTED_IAM_USERS, PROTECTED_IAM_POLICIES
from utils.credentials import filter_credentials, load_credentials
from utils.parallel import run_parallel
from utils.session import get_account_id, make_session

# aws-nuke 실행 파일 이름 — PATH에 있어야 한다
_NUKE_BINARY = "aws-nuke"

# 대상 리전 기본값 — us-east-1 + global(IAM, CloudFront 등 글로벌 서비스)
_DEFAULT_REGIONS = ["us-east-1", "global"]

# 계정 blocklist 에 넣을 더미 ID — 대상 계정과 달라야 aws-nuke 가 실행됨
_BLOCKLIST_DUMMY = "000000000000"

# aws-nuke 실행 전 설정하는 임시 IAM 계정 alias — aws-nuke 안전 체크 통과에 필요
# (alias 없는 계정은 aws-nuke가 실행을 거부함)
_TEMP_ALIAS = "workshop-nuke"


# ── 내부 헬퍼 ─────────────────────────────────────────────────────────────────

def _check_aws_nuke() -> None:
    """aws-nuke 바이너리가 PATH에 있는지 확인한다. 없으면 설치 안내 후 종료한다."""
    if shutil.which(_NUKE_BINARY) is None:
        click.echo(
            f"[오류] '{_NUKE_BINARY}' 바이너리를 찾을 수 없습니다.\n\n"
            "설치 방법:\n"
            "  macOS : brew install aws-nuke\n"
            "  Linux : https://github.com/ekristen/aws-nuke/releases 에서 바이너리 다운로드\n"
            "  설치 후 PATH에 등록되어 있어야 합니다.",
            err=True,
        )
        raise SystemExit(1)


def _build_nuke_config(account_id: str, regions: list[str]) -> dict:
    """
    account_id 계정용 aws-nuke YAML 설정 딕셔너리를 생성한다.

    워크샵 필수 IAM 리소스(유저·액세스키·로그인프로파일·정책·정책연결)는
    삭제 대상에서 제외(filter)하여 수업 운영에 필요한 자격증명을 보호한다.
    """
    protected_users = sorted(EXPECTED_IAM_USERS)
    protected_policies = sorted(PROTECTED_IAM_POLICIES)

    attachment_filters: list[dict] = [
        {"type": "glob", "value": f"{u} -> *"} for u in protected_users
    ]

    return {
        # 삭제 작업을 수행할 리전 목록
        "regions": regions,

        # 절대 삭제하지 않을 계정 ID 목록 (aws-nuke v3: blocklist)
        "blocklist": [_BLOCKLIST_DUMMY],

        # alias 체크 우회 목록 — --no-alias-check CLI 플래그와 반드시 함께 사용해야 한다
        # 워크샵 계정은 SCP(Service Control Policy)로 list_account_aliases가 막혀
        # aws-nuke가 alias를 인식하지 못하므로 명시적으로 우회 대상에 등록한다
        "bypass-alias-check-accounts": [account_id],

        # 워크샵 계정에서 비활성화된 서비스 — 스캔을 건너뛰어 ERRO 로그를 제거한다
        "resource-types": {
            "excludes": [
                # AmazonML — 서비스 종료
                "MachineLearningDataSource", "MachineLearningBranchPrediction",
                "MachineLearningEvaluation", "MachineLearningMLModel",
                # FMS — 미구독
                "FMSPolicy", "FMSNotificationChannel",
                # CloudSearch — 미구독
                "CloudSearchDomain",
                # Shield — 미구독
                "ShieldProtectionGroup", "ShieldProtection",
                # OpsWorks — DNS 없음 / i/o timeout
                "OpsWorksUserProfile", "OpsWorksApp", "OpsWorksLayer",
                "OpsWorksStack", "OpsWorksInstance",
                "OpsWorksCMServer", "OpsWorksCMServerState", "OpsWorksCMBackup",
                # Lex — 503
                "LexModelBuildingServiceBotAlias", "LexModelBuildingServiceBot",
                "LexBot", "LexIntent", "LexSlotType",
                # Cloud9 — 미구독
                "Cloud9Environment",
                # Timestream — 미구독
                "AWS::Timestream::Database", "AWS::Timestream::ScheduledQuery",
                "AWS::Timestream::Table",
                # CodeStar — i/o timeout
                "CodeStarProject",
                # ElasticTranscoder — i/o timeout
                "ElasticTranscoderPipeline", "ElasticTranscoderPreset",
            ]
        },

        # 계정별 삭제 설정
        "accounts": {
            account_id: {
                "filters": {
                    "IAMUser": protected_users,
                    "IAMUserAccessKey": [
                        {"type": "glob", "value": f"{u} -> *"} for u in protected_users
                    ],
                    "IAMLoginProfile": protected_users,
                    "IAMPolicy": [
                        {"type": "glob", "value": f"{p}*"} for p in protected_policies
                    ],
                    "IAMUserPolicyAttachment": attachment_filters,
                    "IAMGroupMembership": [
                        {"type": "glob", "value": f"{u} -> *"} for u in protected_users
                    ],
                }
            }
        },
    }


def _ensure_default_vpc(session, region: str) -> str:
    """
    해당 리전에 default VPC가 없으면 생성한다.
    반환값: "존재함" | "생성됨" | "생성실패: <이유>"
    """
    if region == "global":
        return "해당없음"
    try:
        ec2 = session.client("ec2", region_name=region)
        vpcs = ec2.describe_vpcs(
            Filters=[{"Name": "isDefault", "Values": ["true"]}]
        )["Vpcs"]
        if vpcs:
            return "존재함"
        ec2.create_default_vpc()
        return "생성됨"
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "DefaultVpcAlreadyExists":
            return "존재함"
        return f"생성실패({code})"


def _nuke_account(
    cred: dict,
    dry_run: bool,
    regions: list[str],
    force_sleep: int,
    restore_vpc: bool,
    log_dir: Path | None,
) -> dict | None:
    """
    단일 계정에 대해 aws-nuke 를 병렬 실행하는 워커 함수.

    run_parallel 에 의해 스레드로 실행되며, cred["_update_progress"](pct, msg) 로
    프로그레스바를 갱신한다. aws-nuke 출력은 캡처하여 log_dir 에 저장한다.
    """
    name = cred["name"]
    update = cred["_update_progress"]
    access_key = cred["access_key"]
    secret_key = cred["secret_key"]

    result: dict = {"name": name, "account_id": None, "status": "오류", "vpc": {}}

    try:
        # 1. 계정 ID 조회
        update(5, "계정 ID 조회 중...")
        session = make_session(access_key, secret_key)
        account_id = get_account_id(session)
        if not account_id:
            result["status"] = "자격증명 오류"
            return result
        result["account_id"] = account_id

        # 2. 임시 YAML 설정 생성
        update(10, "설정 파일 생성 중...")
        config_data = _build_nuke_config(account_id, regions)
        tmp_path: str | None = None

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".yaml",
            prefix=f"awsw-nuke-{account_id}-",
            delete=False, encoding="utf-8",
        ) as tmp:
            yaml.dump(config_data, tmp, default_flow_style=False, allow_unicode=True)
            tmp_path = tmp.name

        try:
            # 3. IAM 계정 alias 설정 — aws-nuke 안전 체크 통과에 필수
            # list_account_aliases 권한이 없는 계정에서도 동작하도록
            # list 없이 바로 create → EntityAlreadyExists 이면 이미 존재하는 것으로 처리
            update(15, "alias 설정 중...")
            alias_created = False
            iam_client = session.client("iam")
            try:
                iam_client.create_account_alias(AccountAlias=_TEMP_ALIAS)
                alias_created = True  # 새로 생성됨 — 완료 후 삭제 필요
            except ClientError as e:
                code = e.response["Error"]["Code"]
                if code == "EntityAlreadyExists":
                    alias_created = False  # 이미 존재함 — 삭제 불필요
                else:
                    result["status"] = f"alias 설정 실패({code})"
                    return result

            # 4. aws-nuke 실행 — 출력은 캡처하여 로그 파일에만 저장
            # --no-alias-check: CLI 플래그 + config의 no-alias-check 항목 모두 필요
            update(20, "aws-nuke 실행 중..." if not dry_run else "스캔 중...")
            cmd = [
                _NUKE_BINARY, "run",
                "--config", tmp_path,
                "--no-prompt",
                "--no-alias-check",
                "--force-sleep", str(force_sleep),
            ]
            if not dry_run:
                cmd.append("--no-dry-run")

            env = os.environ.copy()
            env.update({
                "AWS_ACCESS_KEY_ID": access_key,
                "AWS_SECRET_ACCESS_KEY": secret_key,
                "AWS_DEFAULT_REGION": next(
                    (r for r in regions if r != "global"), "us-east-1"
                ),
            })

            proc = subprocess.run(
                cmd, env=env, text=True,
                capture_output=True,  # 출력을 캡처 — 터미널에 직접 뿌리지 않음
            )

            # 로그 파일에 저장 (log_dir 지정 시)
            if log_dir:
                log_path = log_dir / f"nuke-{account_id}.log"
                log_path.write_text(
                    proc.stdout + ("\n\n--- STDERR ---\n" + proc.stderr if proc.stderr else ""),
                    encoding="utf-8",
                )

            rc = proc.returncode

            # 스캔 결과 파싱 — "Scan complete: N total, M nukeable" 추출
            scan_summary = ""
            for line in proc.stdout.splitlines():
                if "Scan complete:" in line:
                    # "Scan complete: 483 total, 107 nukeable, 376 filtered."
                    scan_summary = line.split("Scan complete:")[-1].strip().rstrip(".")
                    break

            if rc == 0:
                result["status"] = f"완료 ✔  {scan_summary}" if scan_summary else "완료 ✔"
            else:
                result["status"] = f"오류 ✘ (exit={rc})"

            # 5. default VPC 복원 (실제 삭제 후에만)
            if restore_vpc and not dry_run and rc == 0:
                update(90, "VPC 복원 중...")
                target_regions = [r for r in regions if r != "global"] or ["us-east-1"]
                for r in target_regions:
                    result["vpc"][r] = _ensure_default_vpc(session, r)

            # 6. 이번 실행에서 새로 만든 alias만 삭제 — 기존에 있던 alias는 건드리지 않음
            if alias_created:
                try:
                    iam_client.delete_account_alias(AccountAlias=_TEMP_ALIAS)
                except ClientError:
                    pass  # 삭제 실패해도 nuke 결과에 영향 없음

        finally:
            if tmp_path and Path(tmp_path).exists():
                Path(tmp_path).unlink()

        update(100, result["status"])
        return result

    except Exception as e:
        result["status"] = f"예외: {e}"
        update(100, result["status"])
        return result


# ── Click 커맨드 ───────────────────────────────────────────────────────────────

@click.command()
@click.option(
    "--credentials-file", "-c",
    default="accesskey.txt", show_default=True,
    help="자격증명 파일 경로 (탭 구분 access_key + secret_key)",
)
@click.option(
    "--filter", "-f", "account_filter",
    default=None,
    help="처리할 계정 범위 (예: 1-5, 1,3,5). 미지정 시 전체 계정 처리",
)
@click.option(
    "--dry-run/--no-dry-run",
    default=True, show_default=True,
    help="dry-run 모드 (기본 활성화). --no-dry-run 을 지정해야 실제로 삭제됨",
)
@click.option(
    "--region", "-r",
    multiple=True, default=None,
    help=f"대상 리전 (여러 번 지정 가능). 미지정 시 기본값: {', '.join(_DEFAULT_REGIONS)}",
)
@click.option(
    "--force-sleep",
    default=3, show_default=True, type=int,
    help="--force 후 안전 대기 시간(초). aws-nuke 최솟값 3초",
)
@click.option(
    "--restore-vpc/--no-restore-vpc",
    default=True, show_default=True,
    help="실제 삭제 완료 후 각 리전의 default VPC 자동 복원",
)
@click.option(
    "--log-dir",
    default="snapshots/nuke-logs", show_default=True,
    help="계정별 aws-nuke 상세 로그를 저장할 디렉터리",
)
@click.option(
    "--yes", "-y", is_flag=True,
    help="--no-dry-run 모드에서 확인 프롬프트 생략",
)
def cmd(credentials_file, account_filter, dry_run, region, force_sleep,
        restore_vpc, log_dir, yes):
    """
    aws-nuke 를 사용해 계정의 AWS 리소스를 일괄 삭제한다.

    \b
    모든 계정을 병렬로 실행하고 프로그레스바와 요약 결과만 출력한다.
    상세 로그는 --log-dir 디렉터리에 계정별 파일로 저장된다.

    \b
    예시:
      awsw nuke                           # 전체 계정 dry-run
      awsw nuke -f 1-3                    # 계정 1~3만 dry-run
      awsw nuke --no-dry-run -y           # 전체 계정 실제 삭제 + VPC 복원
      awsw nuke --no-dry-run -f 2         # 계정 2만 실제 삭제
      awsw nuke --no-dry-run --no-restore-vpc -y  # 삭제만, VPC 복원 안함
    """
    _check_aws_nuke()

    regions = list(region) if region else _DEFAULT_REGIONS

    credentials = load_credentials(credentials_file)
    credentials = filter_credentials(credentials, account_filter)
    if not credentials:
        click.echo("처리할 계정이 없습니다.", err=True)
        return

    # 로그 디렉터리 생성
    log_path = Path(log_dir)
    log_path.mkdir(parents=True, exist_ok=True)

    # 실제 삭제 전 확인
    if not dry_run:
        click.echo(
            f"\n[경고] --no-dry-run 모드입니다.\n"
            f"  대상 계정 수 : {len(credentials)}개\n"
            f"  대상 리전    : {', '.join(regions)}\n"
            f"  보호 유저    : {', '.join(sorted(EXPECTED_IAM_USERS))}\n",
            err=True,
        )
        if not yes:
            click.confirm("위 계정의 AWS 리소스를 실제로 삭제하시겠습니까?", abort=True)

    # 병렬 실행 — 계정별 프로그레스바 표시, 로그는 파일로만 저장
    worker = partial(
        _nuke_account,
        dry_run=dry_run,
        regions=regions,
        force_sleep=force_sleep,
        restore_vpc=restore_vpc,
        log_dir=log_path,
    )
    results = run_parallel(worker, credentials)

    # 최종 요약 출력
    mode_label = "DRY-RUN" if dry_run else "실제 삭제"
    click.echo(f"\n{'═'*64}")
    click.echo(f"  결과 요약 ({mode_label}) — 상세 로그: {log_path}/")
    click.echo(f"{'═'*64}")
    for r in sorted(results, key=lambda x: x["name"]):
        aid = r.get("account_id") or "조회실패"
        click.echo(f"  {r['name']:<10} | {aid} | {r['status']}")
        for region_name, vpc_status in r.get("vpc", {}).items():
            click.echo(f"    └ VPC [{region_name}]: {vpc_status}")
    click.echo(f"{'═'*64}\n")
