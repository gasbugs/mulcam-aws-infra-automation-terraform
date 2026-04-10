# =============================================================================
# utils/iam_helpers.py
# IAM 리소스 삭제를 위한 저수준 헬퍼 함수
#
# IAM 리소스는 삭제 전 연결된 정책·프로파일 등을 먼저 분리해야 한다.
# 이 파일의 함수들은 그 선행 작업을 포함한 '안전한 강제 삭제' 패턴을 제공한다.
# =============================================================================
from __future__ import annotations

from botocore.exceptions import ClientError


def force_delete_iam_user(iam, username: str, log: list) -> None:
    """IAM 사용자 삭제 전 종속 리소스를 모두 제거한 뒤 삭제한다.

    IAM 사용자를 바로 지우면 오류가 발생하므로 액세스 키·MFA·인증서·
    그룹·정책·서비스 자격증명 등을 먼저 하나씩 제거한 뒤 최종 삭제한다.
    """
    # 프로그래밍 방식 액세스에 사용하는 액세스 키 삭제
    for key in iam.list_access_keys(UserName=username).get("AccessKeyMetadata", []):
        iam.delete_access_key(UserName=username, AccessKeyId=key["AccessKeyId"])

    # 콘솔 로그인에 사용하는 패스워드(로그인 프로파일) 삭제
    try:
        iam.delete_login_profile(UserName=username)
    except iam.exceptions.NoSuchEntityException:
        # 로그인 프로파일이 없는 경우 무시
        pass

    # MFA(다중 인증) 디바이스 비활성화 및 삭제
    for mfa in iam.list_mfa_devices(UserName=username).get("MFADevices", []):
        iam.deactivate_mfa_device(UserName=username, SerialNumber=mfa["SerialNumber"])
        try:
            iam.delete_virtual_mfa_device(SerialNumber=mfa["SerialNumber"])
        except ClientError:
            # 실제 MFA 기기(하드웨어)는 가상 삭제 불가이므로 오류 무시
            pass

    # 코드 서명에 사용하는 서명 인증서 삭제
    for cert in iam.list_signing_certificates(UserName=username).get("Certificates", []):
        iam.delete_signing_certificate(UserName=username, CertificateId=cert["CertificateId"])

    # CodeCommit 등 SSH 접근에 사용하는 SSH 퍼블릭 키 삭제
    for key in iam.list_ssh_public_keys(UserName=username).get("SSHPublicKeys", []):
        iam.delete_ssh_public_key(UserName=username, SSHPublicKeyId=key["SSHPublicKeyId"])

    # CodeCommit HTTPS 등 서비스별 자격증명(서비스 특화 패스워드) 삭제
    try:
        creds = iam.list_service_specific_credentials(UserName=username).get(
            "ServiceSpecificCredentials", []
        )
        for cred in creds:
            iam.delete_service_specific_credential(
                UserName=username,
                ServiceSpecificCredentialId=cred["ServiceSpecificCredentialId"],
            )
    except (iam.exceptions.NoSuchEntityException, ClientError):
        pass

    # 사용자가 속한 모든 IAM 그룹에서 제거
    for group in iam.list_groups_for_user(UserName=username).get("Groups", []):
        iam.remove_user_from_group(GroupName=group["GroupName"], UserName=username)

    # 사용자에 연결된 관리형 정책 해제
    for policy in iam.list_attached_user_policies(UserName=username).get("AttachedPolicies", []):
        iam.detach_user_policy(UserName=username, PolicyArn=policy["PolicyArn"])

    # 사용자에 직접 설정된 인라인 정책 삭제
    for pname in iam.list_user_policies(UserName=username).get("PolicyNames", []):
        iam.delete_user_policy(UserName=username, PolicyName=pname)

    # 모든 종속 리소스 제거 후 사용자 본체 삭제
    iam.delete_user(UserName=username)
    log.append(f"  [IAM 정리] 사용자 삭제 완료: {username}")


def force_delete_iam_role(iam, role_name: str, log: list) -> None:
    """IAM 역할 삭제 전 종속 리소스(인스턴스 프로파일·정책·인라인 정책)를 모두 제거한다.

    EC2 인스턴스 프로파일에 연결된 역할은 프로파일을 먼저 분리해야 삭제할 수 있다.
    """
    # EC2 인스턴스 프로파일 분리 — 역할이 EC2에 붙어 있으면 먼저 떼어내야 삭제 가능
    try:
        profiles = iam.list_instance_profiles_for_role(RoleName=role_name).get("InstanceProfiles", [])
    except ClientError:
        profiles = []
    for profile in profiles:
        profile_name = profile["InstanceProfileName"]
        try:
            iam.remove_role_from_instance_profile(InstanceProfileName=profile_name, RoleName=role_name)
        except ClientError:
            pass
        try:
            # 인스턴스 프로파일 자체도 삭제
            iam.delete_instance_profile(InstanceProfileName=profile_name)
        except ClientError:
            pass

    # 역할에 연결된 관리형 정책(AWS 관리형 또는 고객 관리형) 해제
    try:
        attached = iam.list_attached_role_policies(RoleName=role_name).get("AttachedPolicies", [])
    except ClientError:
        attached = []
    for policy in attached:
        try:
            iam.detach_role_policy(RoleName=role_name, PolicyArn=policy["PolicyArn"])
        except ClientError:
            pass

    # 역할에 직접 설정된 인라인 정책 삭제
    try:
        policy_names = iam.list_role_policies(RoleName=role_name).get("PolicyNames", [])
    except ClientError:
        policy_names = []
    for pname in policy_names:
        try:
            iam.delete_role_policy(RoleName=role_name, PolicyName=pname)
        except ClientError:
            pass

    # 모든 종속 리소스 제거 후 역할 삭제
    iam.delete_role(RoleName=role_name)
    log.append(f"  [IAM 정리] 역할 삭제 완료: {role_name}")


def force_delete_iam_policy(iam, policy_arn: str, policy_name: str, log: list) -> None:
    """고객 관리형 IAM 정책을 모든 엔티티에서 분리한 뒤 삭제한다.

    정책이 사용자·그룹·역할에 연결되어 있으면 전부 분리해야만 삭제할 수 있다.
    또한 기본 버전 이외의 이전 버전들도 먼저 삭제해야 한다.
    """
    # 이 정책이 연결된 모든 사용자·그룹·역할 목록 조회
    try:
        entities = iam.list_entities_for_policy(PolicyArn=policy_arn)
    except ClientError:
        entities = {}

    # 연결된 사용자에서 정책 분리
    for user in entities.get("PolicyUsers", []):
        try:
            iam.detach_user_policy(UserName=user["UserName"], PolicyArn=policy_arn)
        except ClientError:
            pass

    # 연결된 그룹에서 정책 분리
    for group in entities.get("PolicyGroups", []):
        try:
            iam.detach_group_policy(GroupName=group["GroupName"], PolicyArn=policy_arn)
        except ClientError:
            pass

    # 연결된 역할에서 정책 분리
    for role in entities.get("PolicyRoles", []):
        try:
            iam.detach_role_policy(RoleName=role["RoleName"], PolicyArn=policy_arn)
        except ClientError:
            pass

    # 기본 버전이 아닌 이전 버전들 삭제 — 정책은 버전 관리를 하므로 기본 버전 외엔 먼저 지워야 한다
    try:
        versions = iam.list_policy_versions(PolicyArn=policy_arn).get("Versions", [])
    except ClientError:
        versions = []
    for ver in versions:
        if not ver["IsDefaultVersion"]:
            try:
                iam.delete_policy_version(PolicyArn=policy_arn, VersionId=ver["VersionId"])
            except ClientError:
                pass

    # 모든 연결 및 이전 버전 제거 후 정책 삭제
    iam.delete_policy(PolicyArn=policy_arn)
    log.append(f"  [IAM 정리] 정책 삭제 완료: {policy_name}")
