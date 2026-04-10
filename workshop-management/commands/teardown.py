# =============================================================================
# commands/teardown.py
# awsw teardown — 수강생 IAM 유저(terraform-user-1) 완전 삭제
#
# 기존 aws-workshop-teardown.py 의 로직을 click 커맨드로 래핑한다.
# =============================================================================
from __future__ import annotations

import glob
import os

import click
from botocore.exceptions import ClientError

from utils.credentials import load_credentials, filter_credentials
from utils.iam_helpers import force_delete_iam_user
from utils.output import flush_log, set_current_account
from utils.parallel import run_parallel
from utils.session import get_account_id, make_session

IAM_USER_NAME = "terraform-user-1"


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def _teardown_account(cred: dict) -> None:
    """단일 계정에서 terraform-user-1 을 완전히 삭제한다."""
    set_current_account(cred["name"])  # 지연 출력 모드에서 계정 로그 버퍼 연결
    account_name = cred["name"]
    log = [f"{'='*60}", f"  [{account_name} / Key: {cred['access_key'][:5]}...] 삭제 시작"]

    session = make_session(cred["access_key"], cred["secret_key"])
    account_id = get_account_id(session)
    if not account_id:
        log += ["  [오류] 계정 ID 조회 실패 — 자격증명을 확인하세요.", f"{'='*60}"]
        flush_log(log)
        return

    log.append(f"  계정 ID: {account_id}")
    iam = session.client("iam")

    # 사용자 존재 여부 확인
    try:
        iam.get_user(UserName=IAM_USER_NAME)
    except iam.exceptions.NoSuchEntityException:
        log += [f"  [건너뜀] 사용자 '{IAM_USER_NAME}'이 존재하지 않습니다.", f"{'='*60}"]
        flush_log(log)
        return
    except ClientError as e:
        log += [f"  [오류] 사용자 조회 실패: {e}", f"{'='*60}"]
        flush_log(log)
        return

    # 연결된 모든 리소스를 제거하고 유저를 삭제한다
    try:
        force_delete_iam_user(iam, IAM_USER_NAME, log)
    except ClientError as e:
        log.append(f"  [오류] 유저 삭제 실패: {e}")

    log += [f"  [{account_name}] 삭제 완료", f"{'='*60}"]
    flush_log(log)


def _delete_credential_csv_files() -> None:
    """워크샵 크레덴셜 CSV 파일(workshop-credentials-*.csv)을 전부 삭제한다."""
    pattern = "workshop-credentials-*.csv"
    files = glob.glob(pattern)
    if not files:
        click.echo(f"\n[정보] 삭제할 크레덴셜 CSV 파일 없음 ({pattern})")
        return
    click.echo(f"\n[크레덴셜 CSV 정리] {len(files)}개 파일 발견:")
    for path in sorted(files):
        try:
            os.remove(path)
            click.echo(f"  [삭제] {path}")
        except OSError as e:
            click.echo(f"  [오류] {path} 삭제 실패: {e}")


# ── click 커맨드 ───────────────────────────────────────────────────────────────

@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
@click.option("--yes", "-y", is_flag=True, help="삭제 확인 프롬프트 생략")
def cmd(credentials_file, account_filter, yes):
    """수강생 IAM 유저(terraform-user-1) 완전 삭제."""
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    click.echo(f"총 {len(creds)}개 계정에서 '{IAM_USER_NAME}'을 삭제합니다.")

    # 파괴적 작업이므로 --yes 없으면 확인 프롬프트 표시
    if not yes:
        click.confirm("계속하시겠습니까?", abort=True)

    run_parallel(_teardown_account, creds)

    click.echo("\n모든 계정 처리 완료.")
    _delete_credential_csv_files()
