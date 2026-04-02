# =============================================================================
# aws-workshop-teardown.py
# [용도] 워크샵 수강생 IAM 사용자(terraform-user-1) 완전 삭제 스크립트
#
# accesskey.txt 에 등록된 모든 루트 계정에서 terraform-user-1 사용자와
# 해당 사용자에 연결된 모든 리소스를 순서대로 정리한 뒤 삭제합니다.
#   1. 연결된 관리형 정책 해제
#   2. 인라인 정책 삭제
#   3. 콘솔 로그인 프로필 삭제
#   4. 액세스 키 삭제
#   5. MFA 디바이스 삭제
#   6. IAM 그룹에서 제거
#   7. 서명 인증서 / SSH 퍼블릭 키 / 서비스별 자격증명 삭제
#   8. 사용자 최종 삭제
#   9. workshop-credentials-*.csv 크레덴셜 파일 전체 삭제
#
# [사전 준비] accesskey.txt — 탭으로 구분된 access_key, secret_key (계정당 1줄)
# [실행 방법] python aws-workshop-teardown.py
# =============================================================================
import boto3
from botocore.exceptions import ClientError
import sys
import glob
import os
import concurrent.futures
import threading

IAM_USER_NAME = "terraform-user-1"

# 계정별 출력 블록이 뒤섞이지 않도록 출력 락 사용
_print_lock = threading.Lock()

def flush_log(lines: list):
    """버퍼링된 로그를 락을 잡고 한 번에 출력"""
    with _print_lock:
        print("\n".join(lines), flush=True)


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
        print(f"오류: '{file_path}' 파일을 찾을 수 없습니다.")
        sys.exit(1)
    return credentials


def get_account_id(session):
    try:
        return session.client("sts").get_caller_identity()["Account"]
    except ClientError:
        return None


# ── 삭제 헬퍼 함수 ─────────────────────────────────────────────────────────────

def detach_all_policies(iam, log):
    """사용자에게 연결된 모든 관리형 정책 해제"""
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


def delete_inline_policies(iam, log):
    """사용자에게 직접 설정된 모든 인라인 정책 삭제"""
    try:
        response = iam.list_user_policies(UserName=IAM_USER_NAME)
        for policy_name in response.get("PolicyNames", []):
            iam.delete_user_policy(UserName=IAM_USER_NAME, PolicyName=policy_name)
            log.append(f"  [삭제] 인라인 정책 삭제: {policy_name}")
    except iam.exceptions.NoSuchEntityException:
        pass
    except ClientError as e:
        log.append(f"  [오류] 인라인 정책 삭제 실패: {e}")


def delete_login_profile(iam, log):
    """콘솔 로그인 프로필(패스워드) 삭제"""
    try:
        iam.delete_login_profile(UserName=IAM_USER_NAME)
        log.append(f"  [삭제] 콘솔 로그인 프로필 삭제 완료")
    except iam.exceptions.NoSuchEntityException:
        log.append(f"  [건너뜀] 콘솔 로그인 프로필 없음")
    except ClientError as e:
        log.append(f"  [오류] 로그인 프로필 삭제 실패: {e}")


def delete_access_keys(iam, log):
    """사용자의 모든 액세스 키 삭제"""
    try:
        response = iam.list_access_keys(UserName=IAM_USER_NAME)
        for key in response.get("AccessKeyMetadata", []):
            iam.delete_access_key(UserName=IAM_USER_NAME, AccessKeyId=key["AccessKeyId"])
            log.append(f"  [삭제] 액세스 키 삭제: {key['AccessKeyId'][:10]}...")
    except iam.exceptions.NoSuchEntityException:
        pass
    except ClientError as e:
        log.append(f"  [오류] 액세스 키 삭제 실패: {e}")


def delete_mfa_devices(iam, log):
    """사용자에게 등록된 모든 MFA 디바이스 비활성화 및 해제"""
    try:
        response = iam.list_mfa_devices(UserName=IAM_USER_NAME)
        for device in response.get("MFADevices", []):
            serial = device["SerialNumber"]
            iam.deactivate_mfa_device(UserName=IAM_USER_NAME, SerialNumber=serial)
            iam.delete_virtual_mfa_device(SerialNumber=serial)
            log.append(f"  [삭제] MFA 디바이스 삭제: {serial}")
    except iam.exceptions.NoSuchEntityException:
        pass
    except ClientError as e:
        log.append(f"  [오류] MFA 디바이스 삭제 실패: {e}")


def remove_from_groups(iam, log):
    """사용자를 모든 IAM 그룹에서 제거"""
    try:
        response = iam.list_groups_for_user(UserName=IAM_USER_NAME)
        for group in response.get("Groups", []):
            iam.remove_user_from_group(GroupName=group["GroupName"], UserName=IAM_USER_NAME)
            log.append(f"  [제거] 그룹에서 제거: {group['GroupName']}")
    except iam.exceptions.NoSuchEntityException:
        pass
    except ClientError as e:
        log.append(f"  [오류] 그룹 제거 실패: {e}")


def delete_signing_certificates(iam, log):
    """사용자의 모든 서명 인증서 삭제"""
    try:
        response = iam.list_signing_certificates(UserName=IAM_USER_NAME)
        for cert in response.get("Certificates", []):
            iam.delete_signing_certificate(UserName=IAM_USER_NAME, CertificateId=cert["CertificateId"])
            log.append(f"  [삭제] 서명 인증서 삭제: {cert['CertificateId'][:10]}...")
    except iam.exceptions.NoSuchEntityException:
        pass
    except ClientError as e:
        log.append(f"  [오류] 서명 인증서 삭제 실패: {e}")


def delete_ssh_public_keys(iam, log):
    """사용자의 모든 SSH 퍼블릭 키 삭제"""
    try:
        response = iam.list_ssh_public_keys(UserName=IAM_USER_NAME)
        for key in response.get("SSHPublicKeys", []):
            iam.delete_ssh_public_key(UserName=IAM_USER_NAME, SSHPublicKeyId=key["SSHPublicKeyId"])
            log.append(f"  [삭제] SSH 퍼블릭 키 삭제: {key['SSHPublicKeyId'][:10]}...")
    except iam.exceptions.NoSuchEntityException:
        pass
    except ClientError as e:
        log.append(f"  [오류] SSH 퍼블릭 키 삭제 실패: {e}")


def delete_service_specific_credentials(iam, log):
    """사용자의 모든 서비스별 자격증명(CodeCommit 등) 삭제"""
    try:
        response = iam.list_service_specific_credentials(UserName=IAM_USER_NAME)
        for cred in response.get("ServiceSpecificCredentials", []):
            iam.delete_service_specific_credential(
                UserName=IAM_USER_NAME,
                ServiceSpecificCredentialId=cred["ServiceSpecificCredentialId"],
            )
            log.append(f"  [삭제] 서비스 자격증명 삭제: {cred['ServiceName']}")
    except iam.exceptions.NoSuchEntityException:
        pass
    except ClientError as e:
        log.append(f"  [오류] 서비스 자격증명 삭제 실패: {e}")


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def teardown_account(access_key, secret_key, account_name):
    log = [f"{'='*60}", f"  [{account_name} / Key: {access_key[:5]}...] 삭제 시작"]

    session = boto3.Session(
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )

    account_id = get_account_id(session)
    if not account_id:
        log.append(f"  [오류] 계정 ID 조회 실패 — 자격증명을 확인하세요.")
        log.append(f"  [{account_name}] 삭제 중단")
        log.append(f"{'='*60}")
        flush_log(log)
        return

    log.append(f"  계정 ID: {account_id}")
    iam = session.client("iam")

    # 사용자 존재 여부 먼저 확인
    try:
        iam.get_user(UserName=IAM_USER_NAME)
    except iam.exceptions.NoSuchEntityException:
        log.append(f"  [건너뜀] 사용자 '{IAM_USER_NAME}'이 존재하지 않습니다.")
        log.append(f"  [{account_name}] 삭제 완료")
        log.append(f"{'='*60}")
        flush_log(log)
        return
    except ClientError as e:
        log.append(f"  [오류] 사용자 조회 실패: {e}")
        log.append(f"  [{account_name}] 삭제 중단")
        log.append(f"{'='*60}")
        flush_log(log)
        return

    # IAM 사용자 삭제 전 연결된 모든 리소스를 순서대로 제거
    detach_all_policies(iam, log)
    delete_inline_policies(iam, log)
    delete_login_profile(iam, log)
    delete_access_keys(iam, log)
    delete_mfa_devices(iam, log)
    remove_from_groups(iam, log)
    delete_signing_certificates(iam, log)
    delete_ssh_public_keys(iam, log)
    delete_service_specific_credentials(iam, log)

    # 최종 사용자 삭제
    try:
        iam.delete_user(UserName=IAM_USER_NAME)
        log.append(f"  [삭제] 사용자 '{IAM_USER_NAME}' 삭제 완료")
    except ClientError as e:
        log.append(f"  [오류] 사용자 삭제 실패: {e}")

    log.append(f"  [{account_name}] 삭제 완료")
    log.append(f"{'='*60}")
    flush_log(log)


# ── 진입점 ────────────────────────────────────────────────────────────────────

def main():
    print("AWS 워크샵 사용자 삭제 스크립트 시작...")
    print(f"  삭제 대상 사용자: {IAM_USER_NAME}\n")

    creds = parse_credentials()
    if not creds:
        print("처리할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    print(f"총 {len(creds)}개의 계정에서 '{IAM_USER_NAME}'을 삭제합니다.")

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = {
            executor.submit(teardown_account, ak, sk, name): name
            for ak, sk, name in creds
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()
            except Exception as e:
                print(f"  [오류] {futures[future]} 처리 중 예외 발생: {e}")

    print("\n모든 계정 처리 완료.")
    delete_credential_csv_files()


def delete_credential_csv_files():
    """워크샵 크레덴셜 CSV 파일(workshop-credentials-*.csv) 전체 삭제"""
    pattern = "workshop-credentials-*.csv"
    files = glob.glob(pattern)

    if not files:
        print(f"\n[정보] 삭제할 크레덴셜 CSV 파일이 없습니다. ({pattern})")
        return

    print(f"\n[크레덴셜 CSV 정리] {len(files)}개 파일 발견:")
    for path in sorted(files):
        try:
            os.remove(path)
            print(f"  [삭제] {path}")
        except OSError as e:
            print(f"  [오류] {path} 삭제 실패: {e}")


if __name__ == "__main__":
    main()
