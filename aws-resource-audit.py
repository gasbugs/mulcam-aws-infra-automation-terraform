# =============================================================================
# aws-resource-audit.py
# [용도] 워크샵 수강생 AWS 계정의 잔여 리소스 감사 스크립트
#
# accesskey.txt 에 등록된 모든 계정을 병렬로 스캔하여
# 삭제되지 않고 남아있는 AWS 리소스(EC2, RDS, EKS, Route53, WAF 등)를
# 계정별로 출력합니다. 비용이 발생할 수 있는 리소스는 [비용주의] 로 표시됩니다.
#
# [사전 준비] accesskey.txt — 탭으로 구분된 access_key, secret_key (계정당 1줄)
# [실행 방법] python aws-resource-audit.py
# =============================================================================
import boto3
from botocore.exceptions import ClientError, NoCredentialsError, BotoCoreError
import sys
import concurrent.futures
import threading

# 계정별 출력 블록이 뒤섞이지 않도록 출력 락 사용
_print_lock = threading.Lock()

# 통계용 결과 수집 (thread-safe)
_results: list = []
_results_lock = threading.Lock()


def flush_log(lines: list):
    """버퍼링된 로그를 락을 잡고 한 번에 출력"""
    with _print_lock:
        print("\n".join(lines), flush=True)


def record_result(entry: dict):
    with _results_lock:
        _results.append(entry)


def _account_sort_key(entry: dict) -> int:
    try:
        return int(entry["account_name"].split()[-1])
    except (ValueError, IndexError):
        return 0

# 검사할 리소스 목록 (Boto3 클라이언트, 리전 범위, API 호출명, 결과 키)
RESOURCE_CHECKS = {
    # === Global Services ===
    "IAM Users": ('iam', 'global', 'list_users', 'Users'),
    "CloudFront": ('cloudfront', 'global', 'list_distributions', 'DistributionList'),
    "WAFv2 ACLs (Global)": ('wafv2', 'global', 'list_web_acls', 'WebACLs'), # WAFv2 글로벌 (CloudFront)
    "Route53 Hosted Zones": ('route53', 'global', 'list_hosted_zones', 'HostedZones'), # [비용주의] Route53
    
    # === Regional Services ===
    "EC2 Instances": ('ec2', 'regional', 'describe_instances', 'Reservations'),
    "VPC": ('ec2', 'regional', 'describe_vpcs', 'Vpcs'),
    "AMI": ('ec2', 'regional', 'describe_images', 'Images'),
    "EBS Snapshots": ('ec2', 'regional', 'describe_snapshots', 'Snapshots'),
    "EBS Volumes": ('ec2', 'regional', 'describe_volumes', 'Volumes'),
    "EIP": ('ec2', 'regional', 'describe_addresses', 'Addresses'),
    "AutoScalingGroups": ('autoscaling', 'regional', 'describe_auto_scaling_groups', 'AutoScalingGroups'),
    "KMS Keys (Disabled CMK)": ('kms', 'regional', 'list_keys', 'Keys'), # [수정] 이름 변경 (Enabled -> Disabled)
    "ELB (v1)": ('elb', 'regional', 'describe_load_balancers', 'LoadBalancerDescriptions'),
    "ELB (v2)": ('elbv2', 'regional', 'describe_load_balancers', 'LoadBalancers'),
    "EKS Clusters": ('eks', 'regional', 'list_clusters', 'clusters'),
    "Lambda": ('lambda', 'regional', 'list_functions', 'Functions'),
    "SecretManager": ('secretsmanager', 'regional', 'list_secrets', 'SecretList'),
    "RDS": ('rds', 'regional', 'describe_db_instances', 'DBInstances'),
    "ECS Clusters": ('ecs', 'regional', 'list_clusters', 'clusterArns'),
    "ECR Repos": ('ecr', 'regional', 'describe_repositories', 'repositories'),
    "CodeBuild": ('codebuild', 'regional', 'list_projects', 'projects'),
    "WAFv2 ACLs (Regional)": ('wafv2', 'regional', 'list_web_acls', 'WebACLs'), # [추가] WAFv2 리전
}

# --- 병렬 작업을 위한 헬퍼 함수 ---

def check_single_service(session, resource_name, config, region):
    """
    지정된 (서비스, 리전) 조합 하나를 검사하고, 경고 문자열을 반환합니다.
    (병렬 스레드에서 실행됨)
    """
    service_client, scope, api_call, result_key = config
    
    try:
        client = session.client(service_client, region_name=region)
        
        # === [필터링] IAM Users ===
        if resource_name == 'IAM Users':
            EXPECTED_USERS = {"terraform-user-0", "terraform-user-1"}
            response = getattr(client, api_call)()
            users = [
                u for u in response.get(result_key, [])
                if 'AWSServiceRole' not in u.get('Arn', '')
                and u.get('UserName') not in EXPECTED_USERS
            ]
            if users:
                user_names = [u['UserName'] for u in users]
                return f"IAM 사용자 {len(users)}명 발견: {', '.join(user_names)}"
        
        # === [필터링] CloudFront (활성화 + 비활성화 모두) ===
        elif resource_name == 'CloudFront':
            response = getattr(client, api_call)()
            distribution_list = response.get(result_key, {})
            all_dists    = distribution_list.get('Items', [])
            enabled_cnt  = sum(1 for d in all_dists if d.get('Enabled'))
            disabled_cnt = len(all_dists) - enabled_cnt
            if all_dists:
                parts = []
                if enabled_cnt:
                    parts.append(f"활성화 {enabled_cnt}개")
                if disabled_cnt:
                    parts.append(f"비활성화 {disabled_cnt}개")
                return f"CloudFront 리소스 {len(all_dists)}개 발견 (글로벌) — {', '.join(parts)}"
        
        # === [수정] KMS Keys (Disabled CMK) ===
        elif resource_name == 'KMS Keys (Disabled CMK)':
            list_resp = client.list_keys()
            keys = list_resp.get(result_key, [])
            disabled_customer_keys = [] # [수정] 변수명 변경
            for key in keys:
                try:
                    desc_resp = client.describe_key(KeyId=key['KeyId'])
                    metadata = desc_resp.get('KeyMetadata', {})
                    # [수정] KeyManager가 CUSTOMER이고, KeyState가 'Disabled'인 것만 검색
                    # 'PendingDeletion' 상태는 'Disabled'가 아니므로 자동으로 제외됩니다.
                    if metadata.get('KeyManager') == 'CUSTOMER' and metadata.get('KeyState') == 'Disabled':
                        disabled_customer_keys.append(key)
                except ClientError: pass
            
            if disabled_customer_keys: # [수정] 변수명 변경
                return f"{resource_name} 리소스 {len(disabled_customer_keys)}개 발견 (리전: {region})"
        
        # === WAFv2 ACLs (Global/CloudFront) — 비용주의 ===
        elif resource_name == 'WAFv2 ACLs (Global)':
            response = client.list_web_acls(Scope='CLOUDFRONT')
            resources = response.get(result_key, [])
            if resources:
                names = [r['Name'] for r in resources]
                return (f"[비용주의] {resource_name} 리소스 {len(resources)}개 발견 (글로벌) "
                        f"→ 이름: {', '.join(names)}")

        # === WAFv2 ACLs (Regional) — 비용주의 ===
        elif resource_name == 'WAFv2 ACLs (Regional)':
            response = client.list_web_acls(Scope='REGIONAL')
            resources = response.get(result_key, [])
            if resources:
                names = [r['Name'] for r in resources]
                return (f"[비용주의] {resource_name} 리소스 {len(resources)}개 발견 (리전: {region}) "
                        f"→ 이름: {', '.join(names)}")

        # === Route53 Hosted Zones — 비용주의 ===
        elif resource_name == 'Route53 Hosted Zones':
            response = client.list_hosted_zones()
            zones = response.get(result_key, [])
            # AWS 내부 위임 영역 제외
            zones = [z for z in zones if not z.get('Config', {}).get('PrivateZone') is None]
            if zones:
                zone_names = [z['Name'].rstrip('.') for z in zones]
                private = [z['Name'].rstrip('.') for z in zones if z.get('Config', {}).get('PrivateZone')]
                public  = [z['Name'].rstrip('.') for z in zones if not z.get('Config', {}).get('PrivateZone')]
                detail = []
                if public:
                    detail.append(f"퍼블릭: {', '.join(public)}")
                if private:
                    detail.append(f"프라이빗: {', '.join(private)}")
                return (f"[비용주의] {resource_name} {len(zones)}개 발견 (글로벌) "
                        f"→ {' / '.join(detail)}")

        # === [필터링] AMI (self-owned) ===
        elif resource_name == 'AMI':
            response = client.describe_images(Owners=['self'])
            if response.get(result_key):
                return f"{resource_name} 리소스 {len(response[result_key])}개 발견 (리전: {region})"
        
        # === [필터링] EBS Snapshots (self-owned) ===
        elif resource_name == 'EBS Snapshots':
            response = client.describe_snapshots(OwnerIds=['self'])
            if response.get(result_key):
                return f"{resource_name} 리소스 {len(response[result_key])}개 발견 (리전: {region})"
        
        # === [필터링] VPC (non-default) ===
        elif resource_name == 'VPC':
            response = client.describe_vpcs(Filters=[{'Name': 'is-default', 'Values': ['false']}])
            if response.get(result_key):
                return f"{resource_name} 리소스 {len(response[result_key])}개 발견 (리전: {region})"
        
        # === [필터링] EC2 Instances (not terminated) ===
        elif resource_name == 'EC2 Instances':
            response = client.describe_instances(Filters=[
                {'Name': 'instance-state-name', 'Values': ['pending', 'running', 'stopping', 'stopped']}
            ])
            if response.get(result_key):
                return f"{resource_name} 리소스 {len(response[result_key])}개 발견 (리전: {region})"

        # === 기타 리소스 (기본 API 호출) ===
        else:
            response = getattr(client, api_call)()
            resources = response.get(result_key, [])
            if resources:
                return f"{resource_name} 리소스 {len(resources)}개 발견 (리전: {region})"
                
    except (ClientError, BotoCoreError) as e:
        # 권한이 없거나, 활성화되지 않은 리전이거나, API 호출이 막힌 경우 (무시)
        # print(f"  [정보] {resource_name} / {region} 검사 중 오류 (무시): {e}")
        pass
    
    return None # 발견된 리소스 없음

# ------------------------------------

def parse_credentials(file_path='accesskey.txt'):
    """accesskey.txt 파일을 파싱하여 (key, secret) 튜플 리스트를 반환"""
    credentials = []
    try:
        with open(file_path, 'r') as f:
            for i, line in enumerate(f):
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                try:
                    access_key, secret_key = line.split('\t')
                    credentials.append((access_key, secret_key, f"계정 {i+1}"))
                except ValueError:
                    print(f"경고: {file_path} 파일의 {i+1}번째 줄 형식이 잘못되었습니다. (탭으로 구분 필요)")
    except FileNotFoundError:
        print(f"오류: {file_path} 파일을 찾을 수 없습니다. 스크립트와 같은 위치에 파일을 생성하세요.")
        sys.exit(1)
    return credentials

def get_enabled_regions(session, log: list):
    """활성화된 모든 리전 목록을 반환"""
    try:
        ec2_client = session.client('ec2', region_name='us-east-1')
        regions = ec2_client.describe_regions(
            Filters=[{'Name': 'opt-in-status', 'Values': ['opted-in', 'opt-in-not-required']}]
        )
        return [r['RegionName'] for r in regions['Regions']]
    except ClientError as e:
        log.append(f"  [오류] 리전 목록을 가져오는 중 에러 발생: {e}")
        log.append("  >> Access Key가 유효한지, 'ec2:DescribeRegions' 권한이 있는지 확인하세요.")
        return None

EXPECTED_IAM_USERS = {"terraform-user-0", "terraform-user-1"}


def _force_delete_iam_user(iam, username: str, log: list):
    """IAM 사용자 삭제 전 필요한 모든 종속 리소스를 제거한 뒤 사용자를 삭제합니다."""
    # 1. 액세스 키 삭제
    for key in iam.list_access_keys(UserName=username).get("AccessKeyMetadata", []):
        iam.delete_access_key(UserName=username, AccessKeyId=key["AccessKeyId"])

    # 2. 로그인 프로필(콘솔 비밀번호) 삭제
    try:
        iam.delete_login_profile(UserName=username)
    except iam.exceptions.NoSuchEntityException:
        pass

    # 3. MFA 디바이스 비활성화 및 해제
    for mfa in iam.list_mfa_devices(UserName=username).get("MFADevices", []):
        iam.deactivate_mfa_device(UserName=username, SerialNumber=mfa["SerialNumber"])
        try:
            iam.delete_virtual_mfa_device(SerialNumber=mfa["SerialNumber"])
        except ClientError:
            pass

    # 4. 서명 인증서 삭제
    for cert in iam.list_signing_certificates(UserName=username).get("Certificates", []):
        iam.delete_signing_certificate(UserName=username, CertificateId=cert["CertificateId"])

    # 5. SSH 공개 키 삭제
    for key in iam.list_ssh_public_keys(UserName=username).get("SSHPublicKeys", []):
        iam.delete_ssh_public_key(UserName=username, SSHPublicKeyId=key["SSHPublicKeyId"])

    # 6. 그룹에서 제거
    for group in iam.list_groups_for_user(UserName=username).get("Groups", []):
        iam.remove_user_from_group(GroupName=group["GroupName"], UserName=username)

    # 7. 관리형 정책 분리
    for policy in iam.list_attached_user_policies(UserName=username).get("AttachedPolicies", []):
        iam.detach_user_policy(UserName=username, PolicyArn=policy["PolicyArn"])

    # 8. 인라인 정책 삭제
    for pname in iam.list_user_policies(UserName=username).get("PolicyNames", []):
        iam.delete_user_policy(UserName=username, PolicyName=pname)

    # 9. 사용자 삭제
    iam.delete_user(UserName=username)
    log.append(f"  [IAM 정리] 사용자 삭제 완료: {username}")


def perform_iam_user_cleanup(session, log: list) -> dict:
    """
    EXPECTED_IAM_USERS 에 속하지 않는 IAM 사용자를 모두 삭제합니다.
    반환: {"deleted": [...], "failed": [...]}
    """
    iam = session.client("iam")
    result = {"deleted": [], "failed": []}

    try:
        users = iam.list_users().get("Users", [])
    except ClientError as e:
        log.append(f"  [IAM 정리] 사용자 목록 조회 실패: {e}")
        return result

    for user in users:
        username = user["UserName"]
        if username in EXPECTED_IAM_USERS or "AWSServiceRole" in user.get("Arn", ""):
            continue
        try:
            _force_delete_iam_user(iam, username, log)
            result["deleted"].append(username)
        except ClientError as e:
            log.append(f"  [IAM 정리] 사용자 삭제 실패 ({username}): {e}")
            result["failed"].append(username)

    return result


def perform_cloudfront_cleanup(session, log: list) -> dict:
    """
    CloudFront 배포를 정리합니다.
    - 활성화(Enabled) + Deployed  → 비활성화 요청 (배포 완료 후 수동 삭제 필요)
    - 비활성화(Disabled) + Deployed → 즉시 삭제
    - InProgress 상태              → 스킵 (변경 불가)

    반환: {"deleted": [...], "disabled": [...], "skipped": [...], "failed": [...]}
    """
    cf = session.client("cloudfront")
    result = {"deleted": [], "disabled": [], "skipped": [], "failed": []}

    try:
        all_dists = []
        paginator = cf.get_paginator("list_distributions")
        for page in paginator.paginate():
            items = page.get("DistributionList", {}).get("Items", [])
            all_dists.extend(items)
    except ClientError as e:
        log.append(f"  [CloudFront 정리] 목록 조회 실패: {e}")
        return result

    if not all_dists:
        return result

    for dist in all_dists:
        dist_id = dist["Id"]
        domain  = dist.get("DomainName", "")
        enabled = dist.get("Enabled", False)
        status  = dist.get("Status", "")

        if status == "InProgress":
            log.append(f"  [CloudFront 정리] 배포 진행 중 — 스킵: {dist_id} ({domain})")
            result["skipped"].append(dist_id)
            continue

        if enabled:
            # 활성 배포 → 비활성화 요청만 수행 (삭제는 Deployed 후 재실행 필요)
            try:
                cfg_resp = cf.get_distribution_config(Id=dist_id)
                cfg = cfg_resp["DistributionConfig"]
                cfg["Enabled"] = False
                cf.update_distribution(Id=dist_id, DistributionConfig=cfg,
                                       IfMatch=cfg_resp["ETag"])
                log.append(f"  [CloudFront 정리] 비활성화 요청 완료: {dist_id} ({domain})"
                           f" — Deployed 후 재실행 시 자동 삭제")
                result["disabled"].append(dist_id)
            except ClientError as e:
                log.append(f"  [CloudFront 정리] 비활성화 실패: {dist_id}: {e}")
                result["failed"].append(dist_id)
        else:
            # 비활성 + Deployed → 즉시 삭제
            try:
                etag = cf.get_distribution(Id=dist_id)["ETag"]
                cf.delete_distribution(Id=dist_id, IfMatch=etag)
                log.append(f"  [CloudFront 정리] 삭제 완료: {dist_id} ({domain})")
                result["deleted"].append(dist_id)
            except ClientError as e:
                log.append(f"  [CloudFront 정리] 삭제 실패: {dist_id}: {e}")
                result["failed"].append(dist_id)

    return result


def check_aws_account(access_key, secret_key, account_name):
    """단일 AWS 계정의 리소스를 병렬로 검사하고 CloudFront를 정리한 뒤 결과를 출력"""
    log = [f"", f"{'='*60}", f"  [{account_name} / Key: {access_key[:5]}...] 계정 검사 시작"]

    try:
        session = boto3.Session(
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key
        )
    except Exception as e:
        log.append(f"  [오류] Boto3 세션 생성 실패: {e}")
        log.append(f"  [{account_name}] 검사 중단")
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({"account_name": account_name, "account_id": None,
                       "status": "error", "warnings": [], "cf_cleanup": {}, "iam_cleanup": {}})
        return

    # 계정 ID 조회
    account_id = None
    try:
        account_id = session.client("sts").get_caller_identity()["Account"]
        log.append(f"  계정 ID: {account_id}")
    except ClientError:
        pass

    enabled_regions = get_enabled_regions(session, log)
    if not enabled_regions:
        log.append(f"  [{account_name}] 검사 중단 (리전 정보 없음)")
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({"account_name": account_name, "account_id": account_id,
                       "status": "error", "warnings": [], "cf_cleanup": {}, "iam_cleanup": {}})
        return

    warnings_found = []
    errors_found = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=30) as executor:
        futures = []
        for resource_name, config in RESOURCE_CHECKS.items():
            service_client, scope, api_call, result_key = config
            if scope == 'global':
                futures.append(executor.submit(
                    check_single_service, session, resource_name, config, 'us-east-1'
                ))
            elif scope == 'regional':
                for region in enabled_regions:
                    futures.append(executor.submit(
                        check_single_service, session, resource_name, config, region
                    ))

        for future in concurrent.futures.as_completed(futures):
            try:
                result_warning = future.result()
                if result_warning:
                    warnings_found.append(result_warning)
            except Exception as e:
                errors_found.append(f"  [오류] 개별 서비스 검사 중 에러: {e}")

    # IAM 사용자 정리 (예약 유저 제외 전부 삭제)
    iam_cleanup = perform_iam_user_cleanup(session, log)

    # CloudFront 정리 (비활성화된 것 삭제, 활성화된 것 비활성화)
    cf_cleanup = perform_cloudfront_cleanup(session, log)

    # 결과 집계
    if errors_found:
        for e in errors_found:
            log.append(e)

    # 정리된 리소스는 잔여로 보지 않음
    def _is_cleaned(w: str) -> bool:
        if "CloudFront" in w and not cf_cleanup["skipped"] and not cf_cleanup["failed"]:
            return True
        if "IAM 사용자" in w and not iam_cleanup["failed"]:
            return True
        return False

    remaining_warnings = [w for w in warnings_found if not _is_cleaned(w)]

    if remaining_warnings:
        log.append(f"  [경고] 발견된 잔여 리소스 ({len(remaining_warnings)}건):")
        for warning in sorted(set(remaining_warnings)):
            log.append(f"    - {warning}")
    else:
        log.append(f"  [성공] 잔여 리소스 없음 — 계정이 깨끗합니다.")

    status = "clean" if not remaining_warnings else "has_resources"
    if errors_found:
        status = "error"

    log.append(f"  [{account_name}] 검사 완료")
    log.append(f"{'='*60}")
    flush_log(log)
    record_result({"account_name": account_name, "account_id": account_id,
                   "status": status, "warnings": list(set(remaining_warnings)),
                   "cf_cleanup": cf_cleanup, "iam_cleanup": iam_cleanup})


def print_summary(total: int):
    """전체 감사 결과 요약을 출력합니다."""
    clean       = [r for r in _results if r["status"] == "clean"]
    has_res     = [r for r in _results if r["status"] == "has_resources"]
    errors      = [r for r in _results if r["status"] == "error"]

    # CloudFront 정리 집계
    cf_deleted  = sum(len(r["cf_cleanup"].get("deleted",  [])) for r in _results)
    cf_disabled = sum(len(r["cf_cleanup"].get("disabled", [])) for r in _results)
    cf_failed   = sum(len(r["cf_cleanup"].get("failed",   [])) for r in _results)
    cf_skipped  = sum(len(r["cf_cleanup"].get("skipped",  [])) for r in _results)

    # IAM 정리 집계
    iam_deleted = sum(len(r["iam_cleanup"].get("deleted", [])) for r in _results)
    iam_failed  = sum(len(r["iam_cleanup"].get("failed",  [])) for r in _results)

    lines = [
        "",
        "=" * 60,
        "  [최종 감사 요약]",
        "=" * 60,
        f"  전체 계정 수          : {total}개",
        f"  깨끗한 계정           : {len(clean)}개",
        f"  잔여 리소스 있음      : {len(has_res)}개",
        f"  검사 오류             : {len(errors)}개",
    ]

    if iam_deleted or iam_failed:
        lines += [
            f"  ─────────────────────────────────────",
            f"  IAM 사용자 정리 현황",
            f"    · 삭제 완료          : {iam_deleted}명",
        ]
        if iam_failed:
            lines.append(f"    · 삭제 실패          : {iam_failed}명")

    if cf_deleted or cf_disabled or cf_failed or cf_skipped:
        lines += [
            f"  ─────────────────────────────────────",
            f"  CloudFront 정리 현황",
            f"    · 삭제 완료          : {cf_deleted}개",
            f"    · 비활성화 요청      : {cf_disabled}개  (재실행 시 삭제 예정)",
            f"    · 삭제/비활성화 실패 : {cf_failed}개",
            f"    · 배포 중 스킵       : {cf_skipped}개",
        ]

    # 잔여 리소스 계정 목록 — 계정 번호 오름차순
    if has_res:
        lines += [
            "",
            "=" * 60,
            "  [잔여 리소스 발견 계정]  (계정 번호 순)",
            "=" * 60,
        ]
        for r in sorted(has_res, key=_account_sort_key):
            aid = r["account_id"] or "ID 미확인"
            lines.append(f"  {r['account_name']:<10}  계정 ID: {aid}  ({len(r['warnings'])}건)")
            for w in sorted(r["warnings"]):
                lines.append(f"    └ {w}")

    # CloudFront 비활성화만 된 계정 (재실행 필요)
    needs_rerun = sorted(
        [r for r in _results if r["cf_cleanup"].get("disabled")],
        key=_account_sort_key,
    )
    if needs_rerun:
        lines += [
            "",
            "=" * 60,
            "  [CloudFront 재실행 필요 계정]  (Deployed 후 재실행하면 삭제됨)",
            "=" * 60,
        ]
        for r in needs_rerun:
            aid = r["account_id"] or "ID 미확인"
            ids = ", ".join(r["cf_cleanup"]["disabled"])
            lines.append(f"  {r['account_name']:<10}  계정 ID: {aid}  배포 ID: {ids}")

    if errors:
        lines += [
            "",
            "=" * 60,
            "  [검사 오류 계정]",
            "=" * 60,
        ]
        for r in sorted(errors, key=_account_sort_key):
            aid = r["account_id"] or "ID 미확인"
            lines.append(f"  {r['account_name']:<10}  계정 ID: {aid}")

    lines.append("=" * 60)
    print("\n".join(lines))


def main():
    print("AWS 수강생 계정 리소스 감사 스크립트 시작...")

    creds = parse_credentials()
    if not creds:
        print("검사할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    print(f"총 {len(creds)}개의 계정을 병렬로 검사합니다. (계정별 결과는 완료 순으로 출력)")

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = {
            executor.submit(check_aws_account, ak, sk, name): name
            for ak, sk, name in creds
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()
            except Exception as e:
                with _print_lock:
                    print(f"[오류] {futures[future]} 처리 중 예외 발생: {e}", flush=True)

    print_summary(len(creds))
    print("\n모든 계정 검사 완료.")

if __name__ == "__main__":
    main()