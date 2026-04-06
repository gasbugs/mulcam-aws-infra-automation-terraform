# =============================================================================
# commands/setup.py
# awsw setup — 수강생 IAM 유저 생성 + 정책 연결 + CSV 출력
#
# 기존 aws-workshop-setup.py 의 로직을 click 커맨드로 래핑한다.
# 공통 처리(자격증명 파싱, 세션 생성, 병렬 실행, 로그 출력)는 utils/ 를 사용한다.
# =============================================================================
from __future__ import annotations

import csv
import json
import os
import secrets
import string
import threading
from datetime import datetime
from functools import partial

import click
from botocore.exceptions import ClientError

from utils.credentials import load_credentials, filter_credentials
from utils.output import flush_log, set_current_account
from utils.parallel import run_parallel
from utils.session import get_account_id, make_session

POLICY_NAME = "TerraformWorkshop-Restricted-us-east-1"
POLICY_FILE = "TerraformWorkshop-Restricted-us-east-1.json"
IAM_USER_NAME = "terraform-user-1"

# CSV 쓰기 경합 방지용 락 (run_parallel 내 스레드들이 공유)
_csv_lock = threading.Lock()


# ── IAM 헬퍼 ──────────────────────────────────────────────────────────────────

def _load_policy_document(file_path: str) -> str:
    """정책 JSON 파일을 읽어 문자열로 반환한다."""
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"정책 파일 '{file_path}'을 찾을 수 없습니다.")
    with open(file_path, "r", encoding="utf-8") as f:
        return json.dumps(json.load(f))


def _generate_password(length: int = 12) -> str:
    """IAM 기본 패스워드 정책을 만족하는 임시 비밀번호를 생성한다.
    대문자, 소문자, 숫자, 특수문자 각 1자 이상 포함."""
    upper, lower, digits, special = (
        string.ascii_uppercase, string.ascii_lowercase,
        string.digits, "!@#$%^&*",
    )
    pwd = [
        secrets.choice(upper), secrets.choice(lower),
        secrets.choice(digits), secrets.choice(special),
    ]
    all_chars = upper + lower + digits + special
    pwd += [secrets.choice(all_chars) for _ in range(length - 4)]
    secrets.SystemRandom().shuffle(pwd)
    return "".join(pwd)


def _find_policy_arn(iam, account_id: str) -> str | None:
    """계정에서 워크샵 정책 ARN을 찾아 반환한다. 없으면 None."""
    paginator = iam.get_paginator("list_policies")
    for page in paginator.paginate(Scope="Local"):
        for policy in page["Policies"]:
            if policy["PolicyName"] == POLICY_NAME:
                return policy["Arn"]
    return None


def _update_policy_document(iam, policy_arn: str, policy_document: str, log: list) -> bool:
    """기존 정책을 새 버전으로 업데이트한다.
    IAM 정책은 최대 5개 버전만 허용하므로 가장 오래된 비기본 버전을 먼저 삭제한다."""
    try:
        versions = iam.list_policy_versions(PolicyArn=policy_arn)["Versions"]
        default = next(v for v in versions if v["IsDefaultVersion"])
        current_doc = iam.get_policy_version(
            PolicyArn=policy_arn, VersionId=default["VersionId"],
        )["PolicyVersion"]["Document"]

        # 내용이 동일하면 업데이트 건너뜀
        if json.dumps(current_doc, sort_keys=True) == json.dumps(json.loads(policy_document), sort_keys=True):
            log.append("  [확인] 정책 내용 변경 없음 — 업데이트 건너뜀")
            return True

        # 버전 5개면 가장 오래된 비기본 버전 삭제
        non_defaults = [v for v in versions if not v["IsDefaultVersion"]]
        if len(versions) >= 5:
            oldest = sorted(non_defaults, key=lambda v: v["CreateDate"])[0]
            iam.delete_policy_version(PolicyArn=policy_arn, VersionId=oldest["VersionId"])
            log.append(f"  [정리] 오래된 정책 버전 삭제: {oldest['VersionId']}")

        iam.create_policy_version(PolicyArn=policy_arn, PolicyDocument=policy_document, SetAsDefault=True)
        log.append(f"  [업데이트] 정책 새 버전으로 업데이트 완료")
        return True
    except ClientError as e:
        log.append(f"  [오류] 정책 업데이트 실패: {e}")
        return False


def _ensure_policy(iam, account_id: str, policy_document: str, log: list) -> str | None:
    """정책이 없으면 생성, 있으면 내용 확인 후 필요시 업데이트한다. ARN 반환."""
    existing_arn = _find_policy_arn(iam, account_id)
    if existing_arn:
        _update_policy_document(iam, existing_arn, policy_document, log)
        return existing_arn
    try:
        arn = iam.create_policy(
            PolicyName=POLICY_NAME,
            PolicyDocument=policy_document,
            Description="Terraform workshop — us-east-1 only, no costly services",
        )["Policy"]["Arn"]
        log.append(f"  [생성] 정책 생성 완료: {arn}")
        return arn
    except ClientError as e:
        log.append(f"  [오류] 정책 생성 실패: {e}")
        return None


def _ensure_user(iam, log: list) -> None:
    """IAM 사용자가 없으면 생성한다."""
    try:
        iam.get_user(UserName=IAM_USER_NAME)
        log.append(f"  [확인] 사용자 이미 존재: {IAM_USER_NAME}")
    except iam.exceptions.NoSuchEntityException:
        try:
            iam.create_user(UserName=IAM_USER_NAME)
            log.append(f"  [생성] 사용자 생성 완료: {IAM_USER_NAME}")
        except ClientError as e:
            log.append(f"  [오류] 사용자 생성 실패: {e}")


def _ensure_policy_attached(iam, policy_arn: str, log: list) -> None:
    """정책이 사용자에게 연결되지 않았으면 연결한다."""
    try:
        for p in iam.list_attached_user_policies(UserName=IAM_USER_NAME)["AttachedPolicies"]:
            if p["PolicyArn"] == policy_arn:
                log.append("  [확인] 정책이 이미 사용자에게 연결되어 있습니다.")
                return
    except ClientError as e:
        log.append(f"  [오류] 연결된 정책 조회 실패: {e}")
        return
    try:
        iam.attach_user_policy(UserName=IAM_USER_NAME, PolicyArn=policy_arn)
        log.append("  [연결] 정책 → 사용자 연결 완료")
    except ClientError as e:
        log.append(f"  [오류] 정책 연결 실패: {e}")


def _ensure_console_access(iam, account_id: str, log: list) -> tuple[str | None, str]:
    """콘솔 로그인 프로필이 없으면 생성하고 (초기패스워드, 로그인URL) 를 반환한다.
    이미 있으면 패스워드는 None을 반환한다."""
    login_url = f"https://{account_id}.signin.aws.amazon.com/console"
    try:
        iam.get_login_profile(UserName=IAM_USER_NAME)
        log.append("  [확인] 콘솔 로그인 프로필 이미 존재 — 패스워드 변경 없음")
        return None, login_url
    except iam.exceptions.NoSuchEntityException:
        pass
    except ClientError as e:
        log.append(f"  [오류] 로그인 프로필 조회 실패: {e}")
        return None, login_url

    password = _generate_password()
    try:
        iam.create_login_profile(
            UserName=IAM_USER_NAME, Password=password, PasswordResetRequired=True,
        )
        log.append("  [생성] 콘솔 로그인 프로필 생성 완료 (최초 로그인 시 패스워드 변경 필요)")
        return password, login_url
    except ClientError as e:
        log.append(f"  [오류] 로그인 프로필 생성 실패: {e}")
        return None, login_url


def _write_csv_row(csv_file: str, row: dict) -> None:
    """스레드 안전하게 CSV 파일에 한 행을 추가한다."""
    fieldnames = ["계정명", "계정ID", "사용자명", "초기패스워드", "로그인URL", "비고"]
    file_exists = os.path.exists(csv_file)
    with _csv_lock:
        with open(csv_file, "a", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            if not file_exists or f.tell() == 0:
                writer.writeheader()
            writer.writerow(row)


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def _setup_account(cred: dict, policy_document: str, csv_file: str) -> None:
    """단일 계정에 대해 사용자 생성, 정책 연결, 콘솔 접근 설정을 수행한다."""
    set_current_account(cred["name"])  # 지연 출력 모드에서 계정 로그 버퍼 연결
    account_name = cred["name"]
    log = [f"{'='*60}", f"  [{account_name} / Key: {cred['access_key'][:5]}...] 설정 시작"]

    session = make_session(cred["access_key"], cred["secret_key"])
    account_id = get_account_id(session)
    if not account_id:
        log += ["  [오류] 계정 ID 조회 실패 — 자격증명을 확인하세요.", f"{'='*60}"]
        flush_log(log)
        return

    log.append(f"  계정 ID: {account_id}")
    iam = session.client("iam")

    policy_arn = _ensure_policy(iam, account_id, policy_document, log)
    if not policy_arn:
        log += [f"  [{account_name}] 설정 중단 (정책 ARN 없음)", f"{'='*60}"]
        flush_log(log)
        return

    _ensure_user(iam, log)
    _ensure_policy_attached(iam, policy_arn, log)
    password, login_url = _ensure_console_access(iam, account_id, log)

    note = "신규 생성 — 첫 로그인 시 패스워드 변경 필요" if password else "기존 프로필 유지 — 패스워드 미변경"
    _write_csv_row(csv_file, {
        "계정명": account_name,
        "계정ID": account_id,
        "사용자명": IAM_USER_NAME,
        "초기패스워드": password if password else "(기존 패스워드 유지)",
        "로그인URL": login_url,
        "비고": note,
    })

    log += [f"  로그인 URL: {login_url}", f"  [{account_name}] 설정 완료", f"{'='*60}"]
    flush_log(log)


# ── click 커맨드 ───────────────────────────────────────────────────────────────

@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
def cmd(credentials_file, account_filter):
    """수강생 IAM 유저 생성 + 정책 연결 + CSV 출력."""
    # 정책 파일 로드
    try:
        policy_document = _load_policy_document(POLICY_FILE)
    except FileNotFoundError as e:
        click.echo(f"오류: {e}", err=True)
        raise SystemExit(1)

    # 자격증명 로드 및 필터 적용
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    csv_file = f"workshop-credentials-{datetime.now().strftime('%Y%m%d-%H%M%S')}.csv"
    click.echo(f"AWS 워크샵 계정 설정 시작 — 총 {len(creds)}개 계정")
    click.echo(f"  정책 파일   : {POLICY_FILE}")
    click.echo(f"  생성할 유저 : {IAM_USER_NAME}")
    click.echo(f"  출력 CSV   : {csv_file}\n")

    # 계정별 병렬 처리
    fn = partial(_setup_account, policy_document=policy_document, csv_file=csv_file)
    run_parallel(fn, creds)

    click.echo(f"\n모든 계정 처리 완료. 로그인 정보 → '{csv_file}'")
