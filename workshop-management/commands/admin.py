# =============================================================================
# commands/admin.py
# awsw admin — terraform-user-0 에 AdministratorAccess 단독 연결 보장
#
# 기존 aws-user-admin-setup.py 의 로직을 click 커맨드로 래핑한다.
# =============================================================================
from __future__ import annotations

import click
from botocore.exceptions import ClientError

from utils.credentials import filter_credentials, load_credentials
from utils.output import flush_log, set_current_account
from utils.parallel import run_parallel
from utils.session import get_account_id, make_session

TARGET_USER      = "terraform-user-0"
ADMIN_POLICY_ARN = "arn:aws:iam::aws:policy/AdministratorAccess"


# ── IAM 헬퍼 ──────────────────────────────────────────────────────────────────

def _ensure_user(iam, log: list) -> bool:
    """사용자가 없으면 생성, 있으면 확인만 한다."""
    try:
        iam.get_user(UserName=TARGET_USER)
        log.append(f"  [확인] 사용자 이미 존재: {TARGET_USER}")
        return True
    except iam.exceptions.NoSuchEntityException:
        try:
            iam.create_user(UserName=TARGET_USER)
            log.append(f"  [생성] 사용자 생성 완료: {TARGET_USER}")
            return True
        except ClientError as e:
            log.append(f"  [오류] 사용자 생성 실패: {e}")
            return False


def _detach_extra_policies(iam, log: list) -> bool:
    """AdministratorAccess 이외의 관리형 정책을 분리한다.
    AdministratorAccess 가 이미 연결된 경우 True 를 반환한다."""
    admin_attached = False
    try:
        paginator = iam.get_paginator("list_attached_user_policies")
        for page in paginator.paginate(UserName=TARGET_USER):
            for policy in page["AttachedPolicies"]:
                if policy["PolicyArn"] == ADMIN_POLICY_ARN:
                    admin_attached = True
                    log.append("  [확인] AdministratorAccess 이미 연결됨")
                else:
                    try:
                        iam.detach_user_policy(UserName=TARGET_USER, PolicyArn=policy["PolicyArn"])
                        log.append(f"  [분리] 관리형 정책 분리: {policy['PolicyName']}")
                    except ClientError as e:
                        log.append(f"  [오류] 정책 분리 실패 ({policy['PolicyName']}): {e}")
    except ClientError as e:
        log.append(f"  [오류] 연결된 정책 조회 실패: {e}")
    return admin_attached


def _delete_inline_policies(iam, log: list) -> None:
    """사용자에게 직접 부여된 모든 인라인 정책을 삭제한다."""
    try:
        inline_names = []
        paginator = iam.get_paginator("list_user_policies")
        for page in paginator.paginate(UserName=TARGET_USER):
            inline_names.extend(page["PolicyNames"])

        if not inline_names:
            log.append("  [확인] 인라인 정책 없음")
            return
        for name in inline_names:
            try:
                iam.delete_user_policy(UserName=TARGET_USER, PolicyName=name)
                log.append(f"  [삭제] 인라인 정책 삭제: {name}")
            except ClientError as e:
                log.append(f"  [오류] 인라인 정책 삭제 실패 ({name}): {e}")
    except ClientError as e:
        log.append(f"  [오류] 인라인 정책 목록 조회 실패: {e}")


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def _setup_admin(cred: dict) -> None:
    set_current_account(cred["name"])  # 지연 출력 모드에서 계정 로그 버퍼 연결
    account_name = cred["name"]
    log = [f"{'='*60}", f"  [{account_name} / Key: {cred['access_key'][:5]}...] 처리 시작"]

    session = make_session(cred["access_key"], cred["secret_key"])
    account_id = get_account_id(session)
    if not account_id:
        log += ["  [오류] 계정 ID 조회 실패", f"{'='*60}"]
        flush_log(log)
        return

    log.append(f"  계정 ID: {account_id}")
    iam = session.client("iam")

    if not _ensure_user(iam, log):
        log += [f"  [{account_name}] 처리 중단 (사용자 생성 실패)", f"{'='*60}"]
        flush_log(log)
        return

    admin_attached = _detach_extra_policies(iam, log)
    _delete_inline_policies(iam, log)

    if not admin_attached:
        try:
            iam.attach_user_policy(UserName=TARGET_USER, PolicyArn=ADMIN_POLICY_ARN)
            log.append("  [연결] AdministratorAccess 연결 완료")
        except ClientError as e:
            log.append(f"  [오류] AdministratorAccess 연결 실패: {e}")

    log += [f"  [{account_name}] 처리 완료", f"{'='*60}"]
    flush_log(log)


# ── click 커맨드 ───────────────────────────────────────────────────────────────

@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
def cmd(credentials_file, account_filter):
    """terraform-user-0 AdministratorAccess 권한 보장."""
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    click.echo(f"terraform-user-0 어드민 권한 보장 시작 — 총 {len(creds)}개 계정\n")
    run_parallel(_setup_admin, creds)
    click.echo("\n모든 계정 처리 완료.")
