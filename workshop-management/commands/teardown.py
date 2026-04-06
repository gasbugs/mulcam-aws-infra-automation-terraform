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
from utils.output import flush_log, set_current_account
from utils.parallel import run_parallel
from utils.session import get_account_id, make_session

IAM_USER_NAME = "terraform-user-1"


# ── IAM 삭제 헬퍼 ─────────────────────────────────────────────────────────────

def _detach_all_policies(iam, log: list) -> None:
    """사용자에게 연결된 모든 관리형 정책을 해제한다."""
    try:
        paginator = iam.get_paginator("list_attached_user_policies")
        for page in paginator.paginate(UserName=IAM_USER_NAME):
            for policy in page["AttachedPolicies"]:
                iam.detach_user_policy(UserName=IAM_USER_NAME, PolicyArn=policy["PolicyArn"])
                log.append(f"  [해제] 정책 연결 해제: {policy['PolicyName']}")
    except iam.exceptions.NoSuchEntityException:
        pass
    except ClientError as e:
        log.append(f"  [오류] 정책 해제 실패: {e}")


def _delete_inline_policies(iam, log: list) -> None:
    """사용자에게 직접 설정된 모든 인라인 정책을 삭제한다."""
    try:
        for name in iam.list_user_policies(UserName=IAM_USER_NAME).get("PolicyNames", []):
            iam.delete_user_policy(UserName=IAM_USER_NAME, PolicyName=name)
            log.append(f"  [삭제] 인라인 정책 삭제: {name}")
    except (iam.exceptions.NoSuchEntityException, ClientError) as e:
        if isinstance(e, ClientError):
            log.append(f"  [오류] 인라인 정책 삭제 실패: {e}")


def _delete_login_profile(iam, log: list) -> None:
    """콘솔 로그인 프로필(패스워드)을 삭제한다."""
    try:
        iam.delete_login_profile(UserName=IAM_USER_NAME)
        log.append("  [삭제] 콘솔 로그인 프로필 삭제 완료")
    except iam.exceptions.NoSuchEntityException:
        log.append("  [건너뜀] 콘솔 로그인 프로필 없음")
    except ClientError as e:
        log.append(f"  [오류] 로그인 프로필 삭제 실패: {e}")


def _delete_access_keys(iam, log: list) -> None:
    """사용자의 모든 액세스 키를 삭제한다."""
    try:
        for key in iam.list_access_keys(UserName=IAM_USER_NAME).get("AccessKeyMetadata", []):
            iam.delete_access_key(UserName=IAM_USER_NAME, AccessKeyId=key["AccessKeyId"])
            log.append(f"  [삭제] 액세스 키 삭제: {key['AccessKeyId'][:10]}...")
    except (iam.exceptions.NoSuchEntityException, ClientError) as e:
        if isinstance(e, ClientError):
            log.append(f"  [오류] 액세스 키 삭제 실패: {e}")


def _delete_mfa_devices(iam, log: list) -> None:
    """사용자에게 등록된 모든 MFA 디바이스를 비활성화하고 삭제한다."""
    try:
        for device in iam.list_mfa_devices(UserName=IAM_USER_NAME).get("MFADevices", []):
            serial = device["SerialNumber"]
            iam.deactivate_mfa_device(UserName=IAM_USER_NAME, SerialNumber=serial)
            iam.delete_virtual_mfa_device(SerialNumber=serial)
            log.append(f"  [삭제] MFA 디바이스 삭제: {serial}")
    except (iam.exceptions.NoSuchEntityException, ClientError) as e:
        if isinstance(e, ClientError):
            log.append(f"  [오류] MFA 디바이스 삭제 실패: {e}")


def _remove_from_groups(iam, log: list) -> None:
    """사용자를 모든 IAM 그룹에서 제거한다."""
    try:
        for group in iam.list_groups_for_user(UserName=IAM_USER_NAME).get("Groups", []):
            iam.remove_user_from_group(GroupName=group["GroupName"], UserName=IAM_USER_NAME)
            log.append(f"  [제거] 그룹에서 제거: {group['GroupName']}")
    except (iam.exceptions.NoSuchEntityException, ClientError) as e:
        if isinstance(e, ClientError):
            log.append(f"  [오류] 그룹 제거 실패: {e}")


def _delete_signing_certificates(iam, log: list) -> None:
    """사용자의 모든 서명 인증서를 삭제한다."""
    try:
        for cert in iam.list_signing_certificates(UserName=IAM_USER_NAME).get("Certificates", []):
            iam.delete_signing_certificate(UserName=IAM_USER_NAME, CertificateId=cert["CertificateId"])
            log.append(f"  [삭제] 서명 인증서 삭제: {cert['CertificateId'][:10]}...")
    except (iam.exceptions.NoSuchEntityException, ClientError) as e:
        if isinstance(e, ClientError):
            log.append(f"  [오류] 서명 인증서 삭제 실패: {e}")


def _delete_ssh_public_keys(iam, log: list) -> None:
    """사용자의 모든 SSH 퍼블릭 키를 삭제한다."""
    try:
        for key in iam.list_ssh_public_keys(UserName=IAM_USER_NAME).get("SSHPublicKeys", []):
            iam.delete_ssh_public_key(UserName=IAM_USER_NAME, SSHPublicKeyId=key["SSHPublicKeyId"])
            log.append(f"  [삭제] SSH 퍼블릭 키 삭제: {key['SSHPublicKeyId'][:10]}...")
    except (iam.exceptions.NoSuchEntityException, ClientError) as e:
        if isinstance(e, ClientError):
            log.append(f"  [오류] SSH 퍼블릭 키 삭제 실패: {e}")


def _delete_service_credentials(iam, log: list) -> None:
    """사용자의 모든 서비스별 자격증명(CodeCommit 등)을 삭제한다."""
    try:
        for cred in iam.list_service_specific_credentials(UserName=IAM_USER_NAME).get("ServiceSpecificCredentials", []):
            iam.delete_service_specific_credential(
                UserName=IAM_USER_NAME,
                ServiceSpecificCredentialId=cred["ServiceSpecificCredentialId"],
            )
            log.append(f"  [삭제] 서비스 자격증명 삭제: {cred['ServiceName']}")
    except (iam.exceptions.NoSuchEntityException, ClientError) as e:
        if isinstance(e, ClientError):
            log.append(f"  [오류] 서비스 자격증명 삭제 실패: {e}")


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

    # 사용자에 연결된 모든 리소스를 순서대로 제거한 뒤 최종 삭제
    _detach_all_policies(iam, log)
    _delete_inline_policies(iam, log)
    _delete_login_profile(iam, log)
    _delete_access_keys(iam, log)
    _delete_mfa_devices(iam, log)
    _remove_from_groups(iam, log)
    _delete_signing_certificates(iam, log)
    _delete_ssh_public_keys(iam, log)
    _delete_service_credentials(iam, log)

    try:
        iam.delete_user(UserName=IAM_USER_NAME)
        log.append(f"  [삭제] 사용자 '{IAM_USER_NAME}' 삭제 완료")
    except ClientError as e:
        log.append(f"  [오류] 사용자 삭제 실패: {e}")

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
