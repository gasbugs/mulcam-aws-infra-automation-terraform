# =============================================================================
# aws-user-admin-setup.py
# [용도] terraform-user-0 에 AdministratorAccess 단독 연결 보장 스크립트
#
# accesskey.txt 에 등록된 루트 자격증명으로 아래 순서를 실행합니다.
#   1. terraform-user-0 사용자가 없으면 생성
#   2. 현재 연결된 관리형 정책 중 AdministratorAccess 이외의 정책 모두 분리
#   3. 인라인 정책 모두 삭제
#   4. AdministratorAccess 가 연결되지 않은 경우 연결
#
# [사전 준비] accesskey.txt — 탭으로 구분된 access_key, secret_key (계정당 1줄)
# [실행 방법] python aws-user-admin-setup.py
# =============================================================================
import boto3
import sys
import concurrent.futures
import threading
from botocore.exceptions import ClientError

TARGET_USER      = "terraform-user-0"
ADMIN_POLICY_ARN = "arn:aws:iam::aws:policy/AdministratorAccess"

_print_lock = threading.Lock()


def flush_log(lines: list):
    with _print_lock:
        print("\n".join(lines), flush=True)


def parse_credentials(file_path="accesskey.txt"):
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
                    print(f"경고: {file_path} 의 {i + 1}번째 줄 형식이 잘못되었습니다. (탭 구분 필요)")
    except FileNotFoundError:
        print(f"오류: '{file_path}' 파일을 찾을 수 없습니다.")
        sys.exit(1)
    return credentials


def get_account_id(session):
    try:
        return session.client("sts").get_caller_identity()["Account"]
    except ClientError:
        return None


# ── IAM 헬퍼 ──────────────────────────────────────────────────────────────────

def ensure_user(iam, log):
    """사용자가 없으면 생성, 있으면 확인만."""
    try:
        iam.get_user(UserName=TARGET_USER)
        log.append(f"  [확인] 사용자 이미 존재: {TARGET_USER}")
    except iam.exceptions.NoSuchEntityException:
        try:
            iam.create_user(UserName=TARGET_USER)
            log.append(f"  [생성] 사용자 생성 완료: {TARGET_USER}")
        except ClientError as e:
            log.append(f"  [오류] 사용자 생성 실패: {e}")
            return False
    return True


def detach_extra_managed_policies(iam, log):
    """
    AdministratorAccess 이외의 관리형 정책을 모두 분리합니다.
    AdministratorAccess 가 이미 연결되어 있으면 True 를 반환합니다.
    """
    admin_already_attached = False
    try:
        paginator = iam.get_paginator("list_attached_user_policies")
        for page in paginator.paginate(UserName=TARGET_USER):
            for policy in page["AttachedPolicies"]:
                arn = policy["PolicyArn"]
                name = policy["PolicyName"]
                if arn == ADMIN_POLICY_ARN:
                    admin_already_attached = True
                    log.append(f"  [확인] AdministratorAccess 이미 연결됨")
                else:
                    try:
                        iam.detach_user_policy(UserName=TARGET_USER, PolicyArn=arn)
                        log.append(f"  [분리] 관리형 정책 분리: {name} ({arn})")
                    except ClientError as e:
                        log.append(f"  [오류] 정책 분리 실패 ({name}): {e}")
    except ClientError as e:
        log.append(f"  [오류] 연결된 정책 조회 실패: {e}")
    return admin_already_attached


def delete_inline_policies(iam, log):
    """사용자에게 직접 부여된 인라인 정책을 모두 삭제합니다."""
    try:
        paginator = iam.get_paginator("list_user_policies")
        inline_names = []
        for page in paginator.paginate(UserName=TARGET_USER):
            inline_names.extend(page["PolicyNames"])

        for policy_name in inline_names:
            try:
                iam.delete_user_policy(UserName=TARGET_USER, PolicyName=policy_name)
                log.append(f"  [삭제] 인라인 정책 삭제: {policy_name}")
            except ClientError as e:
                log.append(f"  [오류] 인라인 정책 삭제 실패 ({policy_name}): {e}")

        if not inline_names:
            log.append(f"  [확인] 인라인 정책 없음")
    except ClientError as e:
        log.append(f"  [오류] 인라인 정책 목록 조회 실패: {e}")


def attach_admin_policy(iam, log):
    """AdministratorAccess 를 연결합니다."""
    try:
        iam.attach_user_policy(UserName=TARGET_USER, PolicyArn=ADMIN_POLICY_ARN)
        log.append(f"  [연결] AdministratorAccess 연결 완료")
    except ClientError as e:
        log.append(f"  [오류] AdministratorAccess 연결 실패: {e}")


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def setup_account(access_key, secret_key, account_name):
    log = [
        f"{'='*60}",
        f"  [{account_name} / Key: {access_key[:5]}...] 처리 시작",
    ]

    session = boto3.Session(
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )

    account_id = get_account_id(session)
    if not account_id:
        log.append(f"  [오류] 계정 ID 조회 실패 — 자격증명을 확인하세요.")
        log.append(f"{'='*60}")
        flush_log(log)
        return

    log.append(f"  계정 ID: {account_id}")
    iam = session.client("iam")

    # 1. 사용자 확인/생성
    if not ensure_user(iam, log):
        log.append(f"  [{account_name}] 처리 중단 (사용자 없음)")
        log.append(f"{'='*60}")
        flush_log(log)
        return

    # 2. 관리형 정책 정리 (AdministratorAccess 외 분리)
    admin_already_attached = detach_extra_managed_policies(iam, log)

    # 3. 인라인 정책 전체 삭제
    delete_inline_policies(iam, log)

    # 4. AdministratorAccess 미연결 시 연결
    if not admin_already_attached:
        attach_admin_policy(iam, log)

    log.append(f"  [{account_name}] 처리 완료")
    log.append(f"{'='*60}")
    flush_log(log)


# ── 진입점 ────────────────────────────────────────────────────────────────────

def main():
    print("terraform-user-0 AdministratorAccess 보장 스크립트 시작...\n")

    creds = parse_credentials()
    if not creds:
        print("처리할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    print(f"총 {len(creds)}개의 계정을 처리합니다.")

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = {
            executor.submit(setup_account, ak, sk, name): name
            for ak, sk, name in creds
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()
            except Exception as e:
                with _print_lock:
                    print(f"[오류] {futures[future]} 처리 중 예외 발생: {e}", flush=True)

    print("\n모든 계정 처리 완료.")


if __name__ == "__main__":
    main()
