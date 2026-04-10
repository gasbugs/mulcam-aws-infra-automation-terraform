# =============================================================================
# commands/cleaners/iam.py
# 학생이 Terraform으로 생성한 IAM 역할·정책·유저를 삭제한다.
# (teardown.py의 terraform-user-1 삭제와는 다르게, 임의 리소스 정리가 목적이다)
# =============================================================================
from __future__ import annotations

from botocore.exceptions import ClientError

from utils.constants import EXPECTED_IAM_USERS, PROTECTED_IAM_POLICIES
from utils.iam_helpers import force_delete_iam_user, force_delete_iam_role, force_delete_iam_policy


def perform_iam_cleanup(session, log: list) -> dict:
    # IAM 클라이언트를 생성하고 삭제 결과를 추적할 딕셔너리를 초기화한다
    iam = session.client("iam")
    result: dict = {"deleted": [], "failed": []}

    # ── 사용자 삭제 ──
    try:
        # 현재 계정의 모든 IAM 사용자 목록을 조회한다
        users = iam.list_users().get("Users", [])
    except ClientError as e:
        log.append(f"  [IAM 정리] 사용자 목록 조회 실패: {e}")
        return result
    for user in users:
        username = user["UserName"]
        # 워크숍 운영에 필요한 사용자이거나 AWS 서비스 연결 사용자는 건너뛴다
        if username in EXPECTED_IAM_USERS or "AWSServiceRole" in user.get("Arn", ""):
            continue
        try:
            force_delete_iam_user(iam, username, log)
            result["deleted"].append(username)
        except ClientError as e:
            log.append(f"  [IAM 정리] 사용자 삭제 실패 ({username}): {e}")
            result["failed"].append(username)

    # ── 역할 삭제 (서비스 연결 역할 제외) ──
    try:
        # AWS가 자동으로 만드는 서비스 연결 역할과 SSO 예약 역할은 삭제 대상에서 제외한다
        roles = [r for r in iam.list_roles().get("Roles", [])
                 if not r.get("Path", "").startswith("/aws-service-role/")
                 and "AWSServiceRole" not in r.get("RoleName", "")
                 and not r.get("RoleName", "").startswith("AWSReservedSSO_")]
    except ClientError as e:
        log.append(f"  [IAM 정리] 역할 목록 조회 실패: {e}")
        roles = []
    for role in roles:
        role_name = role["RoleName"]
        try:
            force_delete_iam_role(iam, role_name, log)
            result["deleted"].append(role_name)
        except ClientError as e:
            log.append(f"  [IAM 정리] 역할 삭제 실패 ({role_name}): {e}")
            result["failed"].append(role_name)

    # ── 고객 관리형 정책 삭제 ──
    try:
        # AWS 관리형 정책(Scope="AWS")은 제외하고 계정 내 직접 만든 정책만 조회한다
        policies = iam.list_policies(Scope="Local").get("Policies", [])
    except ClientError as e:
        log.append(f"  [IAM 정리] 정책 목록 조회 실패: {e}")
        policies = []
    for policy in policies:
        policy_arn  = policy["Arn"]
        policy_name = policy["PolicyName"]
        # 워크숍 운영에 필요한 보호된 정책은 삭제하지 않는다
        if policy_name in PROTECTED_IAM_POLICIES:
            log.append(f"  [IAM 정리] 보호된 정책 — 스킵: {policy_name}")
            continue
        try:
            force_delete_iam_policy(iam, policy_arn, policy_name, log)
            result["deleted"].append(policy_name)
        except ClientError as e:
            log.append(f"  [IAM 정리] 정책 삭제 실패 ({policy_name}): {e}")
            result["failed"].append(policy_name)

    return result
