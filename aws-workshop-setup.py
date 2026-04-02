# =============================================================================
# aws-workshop-setup.py
# [용도] 워크샵 수강생 IAM 사용자 생성 및 콘솔 접근 설정 스크립트
#
# accesskey.txt 에 등록된 모든 루트 계정에 대해 아래 작업을 수행합니다.
#   1. TerraformWorkshop-Restricted-us-east-1 정책이 없으면 JSON 파일로 생성
#   2. terraform-user-1 IAM 사용자가 없으면 생성
#   3. 정책을 사용자에게 연결
#   4. 콘솔 로그인 프로필(초기 패스워드) 생성 — 첫 로그인 시 변경 강제
#   5. 계정별 로그인 URL과 초기 패스워드를 CSV 파일로 저장
#
# [사전 준비] accesskey.txt, TerraformWorkshop-Restricted-us-east-1.json
# [실행 방법] python aws-workshop-setup.py
# =============================================================================
import boto3
from botocore.exceptions import ClientError
import sys
import json
import os
import csv
import secrets
import string
import concurrent.futures
import threading
from datetime import datetime

POLICY_NAME = "TerraformWorkshop-Restricted-us-east-1"
POLICY_FILE = "TerraformWorkshop-Restricted-us-east-1.json"
IAM_USER_NAME = "terraform-user-1"
CSV_FILE = f"workshop-credentials-{datetime.now().strftime('%Y%m%d-%H%M%S')}.csv"

# CSV 쓰기 및 콘솔 출력 경합 방지용 락
_csv_lock = threading.Lock()
_print_lock = threading.Lock()

def flush_log(lines: list):
    """버퍼링된 로그를 락을 잡고 한 번에 출력"""
    with _print_lock:
        print("\n".join(lines), flush=True)


# ── 유틸리티 ───────────────────────────────────────────────────────────────────

def load_policy_document(file_path=POLICY_FILE):
    """정책 JSON 파일을 읽어 문자열로 반환"""
    if not os.path.exists(file_path):
        print(f"오류: 정책 파일 '{file_path}'을 찾을 수 없습니다.")
        sys.exit(1)
    with open(file_path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    return json.dumps(doc)


def parse_credentials(file_path="accesskey.txt"):
    """accesskey.txt 파일을 파싱하여 (access_key, secret_key, 계정명) 튜플 리스트를 반환"""
    credentials = []
    try:
        with open(file_path, "r") as f:
            for i, line in enumerate(f):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                try:
                    access_key, secret_key = line.split("\t")
                    credentials.append((access_key.strip(), secret_key.strip(), f"계정 {i + 1}"))
                except ValueError:
                    print(f"경고: {file_path} 파일의 {i + 1}번째 줄 형식이 잘못되었습니다. (탭으로 구분 필요)")
    except FileNotFoundError:
        print(f"오류: '{file_path}' 파일을 찾을 수 없습니다. 스크립트와 같은 위치에 파일을 생성하세요.")
        sys.exit(1)
    return credentials


def generate_password(length=12):
    """
    IAM 기본 패스워드 정책을 만족하는 임시 비밀번호 생성.
    대문자, 소문자, 숫자, 특수문자 각 1자 이상 포함.
    """
    upper = string.ascii_uppercase
    lower = string.ascii_lowercase
    digits = string.digits
    special = "!@#$%^&*"
    all_chars = upper + lower + digits + special

    # 각 카테고리에서 최소 1자씩 보장
    pwd = [
        secrets.choice(upper),
        secrets.choice(lower),
        secrets.choice(digits),
        secrets.choice(special),
    ]
    pwd += [secrets.choice(all_chars) for _ in range(length - 4)]
    secrets.SystemRandom().shuffle(pwd)
    return "".join(pwd)


def write_csv_row(row: dict):
    """스레드 안전하게 CSV에 한 행 추가"""
    file_exists = os.path.exists(CSV_FILE)
    with _csv_lock:
        with open(CSV_FILE, "a", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(
                f,
                fieldnames=["계정명", "계정ID", "사용자명", "초기패스워드", "로그인URL", "비고"],
            )
            if not file_exists or f.tell() == 0:
                writer.writeheader()
            writer.writerow(row)


# ── IAM 헬퍼 함수 ──────────────────────────────────────────────────────────────

def get_account_id(session):
    try:
        sts = session.client("sts")
        return sts.get_caller_identity()["Account"]
    except ClientError:
        return None


def find_policy_arn(iam, account_id):
    paginator = iam.get_paginator("list_policies")
    for page in paginator.paginate(Scope="Local"):
        for policy in page["Policies"]:
            if policy["PolicyName"] == POLICY_NAME:
                return policy["Arn"]
    return None


def update_policy_document(iam, policy_arn, policy_document, log):
    """
    기존 정책을 새 버전으로 업데이트합니다.
    IAM 정책은 최대 5개 버전만 허용하므로, 비기본 버전 중 가장 오래된 것을 먼저 삭제합니다.
    """
    try:
        # 현재 정책 내용과 비교해 변경이 없으면 건너뜀
        versions = iam.list_policy_versions(PolicyArn=policy_arn)["Versions"]
        default = next(v for v in versions if v["IsDefaultVersion"])
        current_doc = iam.get_policy_version(
            PolicyArn=policy_arn,
            VersionId=default["VersionId"],
        )["PolicyVersion"]["Document"]

        import json as _json
        if _json.dumps(current_doc, sort_keys=True) == _json.dumps(
            _json.loads(policy_document), sort_keys=True
        ):
            log.append(f"  [확인] 정책 내용 변경 없음 — 업데이트 건너뜀")
            return True

        # 버전이 5개면 비기본 버전 중 가장 오래된 것 삭제
        non_defaults = [v for v in versions if not v["IsDefaultVersion"]]
        if len(versions) >= 5:
            oldest = sorted(non_defaults, key=lambda v: v["CreateDate"])[0]
            iam.delete_policy_version(PolicyArn=policy_arn, VersionId=oldest["VersionId"])
            log.append(f"  [정리] 오래된 정책 버전 삭제: {oldest['VersionId']}")

        # 새 버전 생성 및 기본 버전으로 설정
        iam.create_policy_version(
            PolicyArn=policy_arn,
            PolicyDocument=policy_document,
            SetAsDefault=True,
        )
        log.append(f"  [업데이트] 정책 새 버전으로 업데이트 완료: {policy_arn}")
        return True
    except ClientError as e:
        log.append(f"  [오류] 정책 업데이트 실패: {e}")
        return False


def ensure_policy(iam, account_id, policy_document, log):
    existing_arn = find_policy_arn(iam, account_id)
    if existing_arn:
        update_policy_document(iam, existing_arn, policy_document, log)
        return existing_arn

    try:
        response = iam.create_policy(
            PolicyName=POLICY_NAME,
            PolicyDocument=policy_document,
            Description="Terraform workshop — us-east-1 only, no costly services",
        )
        arn = response["Policy"]["Arn"]
        log.append(f"  [생성] 정책 생성 완료: {arn}")
        return arn
    except ClientError as e:
        log.append(f"  [오류] 정책 생성 실패: {e}")
        return None


def ensure_user(iam, log):
    try:
        iam.get_user(UserName=IAM_USER_NAME)
        log.append(f"  [확인] 사용자 이미 존재: {IAM_USER_NAME}")
        return False
    except iam.exceptions.NoSuchEntityException:
        pass

    try:
        iam.create_user(UserName=IAM_USER_NAME)
        log.append(f"  [생성] 사용자 생성 완료: {IAM_USER_NAME}")
        return True
    except ClientError as e:
        log.append(f"  [오류] 사용자 생성 실패: {e}")
        return False


def ensure_policy_attached(iam, policy_arn, log):
    try:
        attached = iam.list_attached_user_policies(UserName=IAM_USER_NAME)
        for p in attached["AttachedPolicies"]:
            if p["PolicyArn"] == policy_arn:
                log.append(f"  [확인] 정책이 이미 사용자에게 연결되어 있습니다.")
                return
    except ClientError as e:
        log.append(f"  [오류] 연결된 정책 조회 실패: {e}")
        return

    try:
        iam.attach_user_policy(UserName=IAM_USER_NAME, PolicyArn=policy_arn)
        log.append(f"  [연결] 정책 → 사용자 연결 완료")
    except ClientError as e:
        log.append(f"  [오류] 정책 연결 실패: {e}")


def ensure_console_access(iam, account_id, log):
    """
    콘솔 로그인 프로필을 확인하고,
    - 없으면 신규 생성 후 (초기패스워드, 로그인URL) 반환
    - 이미 있으면 (None, 로그인URL) 반환 — 패스워드는 재생성하지 않음
    """
    login_url = f"https://{account_id}.signin.aws.amazon.com/console"

    try:
        iam.get_login_profile(UserName=IAM_USER_NAME)
        log.append(f"  [확인] 콘솔 로그인 프로필 이미 존재 — 패스워드 변경 없음")
        return None, login_url
    except iam.exceptions.NoSuchEntityException:
        pass
    except ClientError as e:
        log.append(f"  [오류] 로그인 프로필 조회 실패: {e}")
        return None, login_url

    password = generate_password()
    try:
        iam.create_login_profile(
            UserName=IAM_USER_NAME,
            Password=password,
            PasswordResetRequired=True,
        )
        log.append(f"  [생성] 콘솔 로그인 프로필 생성 완료 (최초 로그인 시 패스워드 변경 필요)")
        return password, login_url
    except ClientError as e:
        log.append(f"  [오류] 로그인 프로필 생성 실패: {e}")
        return None, login_url


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def setup_account(access_key, secret_key, account_name, policy_document):
    log = [f"{'='*60}", f"  [{account_name} / Key: {access_key[:5]}...] 설정 시작"]

    session = boto3.Session(
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )

    account_id = get_account_id(session)
    if not account_id:
        log.append(f"  [오류] 계정 ID 조회 실패 — 자격증명을 확인하세요.")
        log.append(f"  [{account_name}] 설정 중단")
        log.append(f"{'='*60}")
        flush_log(log)
        return

    log.append(f"  계정 ID: {account_id}")
    iam = session.client("iam")

    # 1. 정책 확인/생성
    policy_arn = ensure_policy(iam, account_id, policy_document, log)
    if not policy_arn:
        log.append(f"  [{account_name}] 설정 중단 (정책 ARN 없음)")
        log.append(f"{'='*60}")
        flush_log(log)
        return

    # 2. 사용자 확인/생성
    ensure_user(iam, log)

    # 3. 정책 연결
    ensure_policy_attached(iam, policy_arn, log)

    # 4. 콘솔 접근 설정
    password, login_url = ensure_console_access(iam, account_id, log)

    # 5. CSV 기록
    if password:
        note = "신규 생성 — 첫 로그인 시 패스워드 변경 필요"
    else:
        note = "기존 프로필 유지 — 패스워드 미변경"

    write_csv_row({
        "계정명": account_name,
        "계정ID": account_id,
        "사용자명": IAM_USER_NAME,
        "초기패스워드": password if password else "(기존 패스워드 유지)",
        "로그인URL": login_url,
        "비고": note,
    })

    log.append(f"  로그인 URL: {login_url}")
    log.append(f"  [{account_name}] 설정 완료")
    log.append(f"{'='*60}")
    flush_log(log)


# ── 진입점 ────────────────────────────────────────────────────────────────────

def main():
    print("AWS 워크샵 계정 설정 스크립트 시작...")
    print(f"  정책 파일    : {POLICY_FILE}")
    print(f"  정책 이름    : {POLICY_NAME}")
    print(f"  생성할 사용자  : {IAM_USER_NAME}")
    print(f"  출력 CSV 파일 : {CSV_FILE}\n")

    policy_document = load_policy_document()
    creds = parse_credentials()

    if not creds:
        print("처리할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    print(f"총 {len(creds)}개의 계정을 처리합니다.")

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = {
            executor.submit(setup_account, ak, sk, name, policy_document): name
            for ak, sk, name in creds
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()
            except Exception as e:
                print(f"  [오류] {futures[future]} 처리 중 예외 발생: {e}")

    print(f"\n모든 계정 처리 완료.")
    print(f"로그인 정보가 '{CSV_FILE}' 파일에 저장되었습니다.")


if __name__ == "__main__":
    main()
