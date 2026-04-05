# =============================================================================
# aws-resource-audit.py
# [용도] 워크샵 수강생 AWS 계정의 잔여 리소스 감사 및 정리 스크립트
#
# accesskey.txt 에 등록된 모든 계정을 병렬로 스캔하여
# 삭제되지 않고 남아있는 AWS 리소스(EC2, RDS, EKS, Route53, WAF 등)를
# 계정별로 출력합니다. 비용이 발생할 수 있는 리소스는 [비용주의] 로 표시됩니다.
#
# [사전 준비] accesskey.txt — 탭으로 구분된 access_key, secret_key (계정당 1줄)
# [실행 방법]
#   감사만 (기본값) : python aws-resource-audit.py
#   감사 + 삭제    : python aws-resource-audit.py --delete
# =============================================================================
import argparse
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

def parse_args() -> argparse.Namespace:
    """CLI 인수를 파싱합니다."""
    parser = argparse.ArgumentParser(
        description="워크샵 수강생 AWS 계정 리소스 감사 및 정리 스크립트"
    )
    parser.add_argument(
        "--delete",
        action="store_true",
        default=False,
        # 이 플래그를 주면 감사 후 리소스를 실제로 삭제합니다.
        # 지정하지 않으면 감사(탐지·보고)만 수행합니다.
        help="발견된 리소스를 삭제합니다. 기본값: 감사만 수행",
    )
    parser.add_argument(
        "--key-file",
        default="accesskey.txt",
        # 기본값과 다른 경로의 키 파일을 사용할 때 지정합니다.
        help="액세스 키 파일 경로 (기본값: accesskey.txt)",
        metavar="FILE",
    )
    parser.add_argument(
        "--id",
        type=int,
        default=None,
        # 1-based 순번으로 특정 계정만 검사합니다. 예: --id 3 → accesskey.txt의 3번째 계정만 처리
        help="검사할 계정 순번 (1부터 시작). 생략하면 전체 계정을 대상으로 합니다.",
        metavar="N",
        dest="account_id",
    )
    return parser.parse_args()


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


def perform_ami_cleanup(session, log: list, enabled_regions: list) -> dict:
    """
    모든 활성화 리전에서 자기 소유(self) AMI를 해지(deregister)합니다.
    AMI를 해지해야 연결된 EBS 스냅샷을 이후에 삭제할 수 있습니다.
    반환: {"deregistered": [...], "failed": [...]}
    """
    result = {"deregistered": [], "failed": []}

    for region in enabled_regions:
        try:
            ec2 = session.client('ec2', region_name=region)
            # 자기 계정 소유 AMI만 조회
            images = ec2.describe_images(Owners=['self']).get('Images', [])
            for image in images:
                image_id = image['ImageId']
                try:
                    ec2.deregister_image(ImageId=image_id)
                    log.append(f"  [AMI 정리] 해지 완료: {image_id} (리전: {region})")
                    result["deregistered"].append(image_id)
                except ClientError as e:
                    log.append(f"  [AMI 정리] 해지 실패 ({image_id}): {e}")
                    result["failed"].append(image_id)
        except (ClientError, BotoCoreError):
            # 비활성 리전이거나 권한 없는 경우 무시
            pass

    return result


def perform_ebs_snapshot_cleanup(session, log: list, enabled_regions: list) -> dict:
    """
    모든 활성화 리전에서 자기 소유(self)의 EBS 스냅샷을 전부 삭제합니다.
    반환: {"deleted": [...], "failed": [...]}
    """
    result = {"deleted": [], "failed": []}

    for region in enabled_regions:
        try:
            ec2 = session.client('ec2', region_name=region)
            # 자기 계정 소유 스냅샷만 조회
            snapshots = ec2.describe_snapshots(OwnerIds=['self']).get('Snapshots', [])
            for snap in snapshots:
                snap_id = snap['SnapshotId']
                try:
                    ec2.delete_snapshot(SnapshotId=snap_id)
                    log.append(f"  [스냅샷 정리] 삭제 완료: {snap_id} (리전: {region})")
                    result["deleted"].append(snap_id)
                except ClientError as e:
                    log.append(f"  [스냅샷 정리] 삭제 실패 ({snap_id}): {e}")
                    result["failed"].append(snap_id)
        except (ClientError, BotoCoreError):
            # 비활성 리전이거나 권한 없는 경우 무시
            pass

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


def perform_vpc_cleanup(session, log: list, enabled_regions: list) -> dict:
    """
    모든 활성화 리전에서 기본 VPC(default VPC)를 제외한 나머지 VPC를 삭제합니다.
    VPC는 종속 리소스(IGW, 서브넷, 라우트 테이블, 보안 그룹, 엔드포인트 등)를
    먼저 정리해야 삭제할 수 있으므로, 반드시 다른 리소스 정리 이후 마지막에 실행합니다.
    반환: {"deleted": [...], "failed": [...]}
    """
    result = {"deleted": [], "failed": []}

    for region in enabled_regions:
        try:
            ec2 = session.client('ec2', region_name=region)

            # 기본 VPC가 아닌 VPC만 조회
            vpcs = ec2.describe_vpcs(
                Filters=[{'Name': 'is-default', 'Values': ['false']}]
            ).get('Vpcs', [])

            for vpc in vpcs:
                vpc_id = vpc['VpcId']
                try:
                    # 1단계: 인터넷 게이트웨이(IGW) 분리 후 삭제
                    #        VPC에 연결된 IGW가 있으면 VPC 삭제 불가
                    igws = ec2.describe_internet_gateways(
                        Filters=[{'Name': 'attachment.vpc-id', 'Values': [vpc_id]}]
                    ).get('InternetGateways', [])
                    for igw in igws:
                        igw_id = igw['InternetGatewayId']
                        ec2.detach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc_id)
                        ec2.delete_internet_gateway(InternetGatewayId=igw_id)
                        log.append(f"  [VPC 정리] IGW 삭제: {igw_id} (VPC: {vpc_id}, 리전: {region})")

                    # 2단계: VPC 엔드포인트 삭제
                    #        엔드포인트가 남아 있으면 서브넷 삭제 시 오류 발생 가능
                    endpoints = ec2.describe_vpc_endpoints(
                        Filters=[{'Name': 'vpc-id', 'Values': [vpc_id]},
                                 {'Name': 'vpc-endpoint-state', 'Values': ['available', 'pending']}]
                    ).get('VpcEndpoints', [])
                    if endpoints:
                        ep_ids = [ep['VpcEndpointId'] for ep in endpoints]
                        ec2.delete_vpc_endpoints(VpcEndpointIds=ep_ids)
                        log.append(f"  [VPC 정리] 엔드포인트 삭제: {ep_ids} (VPC: {vpc_id})")

                    # 3단계: 서브넷 삭제
                    subnets = ec2.describe_subnets(
                        Filters=[{'Name': 'vpc-id', 'Values': [vpc_id]}]
                    ).get('Subnets', [])
                    for subnet in subnets:
                        ec2.delete_subnet(SubnetId=subnet['SubnetId'])
                        log.append(f"  [VPC 정리] 서브넷 삭제: {subnet['SubnetId']} (VPC: {vpc_id})")

                    # 4단계: 메인 라우트 테이블을 제외한 나머지 라우트 테이블 삭제
                    rts = ec2.describe_route_tables(
                        Filters=[{'Name': 'vpc-id', 'Values': [vpc_id]}]
                    ).get('RouteTables', [])
                    for rt in rts:
                        # 메인 라우트 테이블은 VPC와 함께 자동 삭제되므로 건너뜀
                        is_main = any(
                            assoc.get('Main') for assoc in rt.get('Associations', [])
                        )
                        if not is_main:
                            ec2.delete_route_table(RouteTableId=rt['RouteTableId'])
                            log.append(f"  [VPC 정리] 라우트 테이블 삭제: {rt['RouteTableId']} (VPC: {vpc_id})")

                    # 5단계: 기본 보안 그룹을 제외한 나머지 보안 그룹 삭제
                    sgs = ec2.describe_security_groups(
                        Filters=[{'Name': 'vpc-id', 'Values': [vpc_id]}]
                    ).get('SecurityGroups', [])
                    for sg in sgs:
                        # 'default' 보안 그룹은 VPC와 함께 자동 삭제되므로 건너뜀
                        if sg['GroupName'] == 'default':
                            continue
                        try:
                            ec2.delete_security_group(GroupId=sg['GroupId'])
                            log.append(f"  [VPC 정리] 보안 그룹 삭제: {sg['GroupId']} (VPC: {vpc_id})")
                        except ClientError:
                            # 다른 리소스가 참조 중이면 무시 (VPC 삭제 시 함께 제거됨)
                            pass

                    # 6단계: VPC 자체 삭제
                    ec2.delete_vpc(VpcId=vpc_id)
                    log.append(f"  [VPC 정리] VPC 삭제 완료: {vpc_id} (리전: {region})")
                    result["deleted"].append(vpc_id)

                except ClientError as e:
                    log.append(f"  [VPC 정리] VPC 삭제 실패 ({vpc_id}, 리전: {region}): {e}")
                    result["failed"].append(vpc_id)

        except (ClientError, BotoCoreError):
            # 비활성 리전이거나 권한 없는 경우 무시
            pass

    return result


def _empty_cleanups() -> dict:
    """delete_mode=False 일 때 record_result 에 채워 넣을 빈 정리 결과"""
    return {
        "iam_cleanup":  {},
        "cf_cleanup":   {},
        "ami_cleanup":  {},
        "snap_cleanup": {},
        "vpc_cleanup":  {},
    }


def check_aws_account(access_key, secret_key, account_name, delete_mode: bool = False):
    """단일 AWS 계정의 리소스를 병렬로 검사하고, delete_mode=True 이면 정리까지 수행합니다."""
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
                       "status": "error", "warnings": [], **_empty_cleanups()})
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
                       "status": "error", "warnings": [], **_empty_cleanups()})
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

    # ── DELETE 단계: --delete 플래그가 있을 때만 실행 ──────────────────────────
    if delete_mode:
        # IAM 사용자 정리 (예약 유저 제외 전부 삭제)
        iam_cleanup = perform_iam_user_cleanup(session, log)

        # CloudFront 정리 (비활성화된 것 삭제, 활성화된 것 비활성화)
        cf_cleanup = perform_cloudfront_cleanup(session, log)

        # AMI 해지 (자기 소유 전부 해지) — 스냅샷보다 먼저 실행해야 참조 해제됨
        ami_cleanup = perform_ami_cleanup(session, log, enabled_regions)

        # EBS 스냅샷 정리 (AMI 해지 후 실행해야 InUse 오류 없이 삭제 가능)
        snap_cleanup = perform_ebs_snapshot_cleanup(session, log, enabled_regions)

        # VPC 정리 — 다른 리소스가 모두 제거된 후 마지막에 실행
        # (EC2, ELB, RDS 등 VPC 종속 리소스가 남아 있으면 삭제 실패)
        vpc_cleanup = perform_vpc_cleanup(session, log, enabled_regions)
    else:
        # audit 모드: 정리 없이 빈 결과로 초기화
        iam_cleanup = cf_cleanup = ami_cleanup = snap_cleanup = vpc_cleanup = {}
    # ────────────────────────────────────────────────────────────────────────────

    # 결과 집계
    if errors_found:
        for e in errors_found:
            log.append(e)

    # delete_mode 일 때만 정리된 항목을 잔여 경고에서 제외
    def _is_cleaned(w: str) -> bool:
        if not delete_mode:
            return False
        if "CloudFront" in w and not cf_cleanup.get("skipped") and not cf_cleanup.get("failed"):
            return True
        if "IAM 사용자" in w and not iam_cleanup.get("failed"):
            return True
        if "AMI" in w and not ami_cleanup.get("failed"):
            return True
        if "EBS Snapshots" in w and not snap_cleanup.get("failed"):
            return True
        if "VPC" in w and not vpc_cleanup.get("failed"):
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
                   "cf_cleanup": cf_cleanup, "iam_cleanup": iam_cleanup,
                   "ami_cleanup": ami_cleanup, "snap_cleanup": snap_cleanup,
                   "vpc_cleanup": vpc_cleanup})


def print_summary(total: int, delete_mode: bool = False):
    """전체 감사(및 정리) 결과 요약을 출력합니다."""
    clean       = [r for r in _results if r["status"] == "clean"]
    has_res     = [r for r in _results if r["status"] == "has_resources"]
    errors      = [r for r in _results if r["status"] == "error"]

    # 헤더: 실행 모드에 따라 다르게 표시
    mode_label = "감사 + 정리" if delete_mode else "감사"
    lines = [
        "",
        "=" * 60,
        f"  [최종 {mode_label} 요약]",
        "=" * 60,
        f"  전체 계정 수          : {total}개",
        f"  깨끗한 계정           : {len(clean)}개",
        f"  잔여 리소스 있음      : {len(has_res)}개",
        f"  검사 오류             : {len(errors)}개",
    ]

    # 정리 통계는 delete_mode 일 때만 출력
    if delete_mode:
        # CloudFront 정리 집계
        cf_deleted  = sum(len(r["cf_cleanup"].get("deleted",  [])) for r in _results)
        cf_disabled = sum(len(r["cf_cleanup"].get("disabled", [])) for r in _results)
        cf_failed   = sum(len(r["cf_cleanup"].get("failed",   [])) for r in _results)
        cf_skipped  = sum(len(r["cf_cleanup"].get("skipped",  [])) for r in _results)

        # IAM 정리 집계
        iam_deleted = sum(len(r["iam_cleanup"].get("deleted", [])) for r in _results)
        iam_failed  = sum(len(r["iam_cleanup"].get("failed",  [])) for r in _results)

        # AMI 정리 집계
        ami_deregistered = sum(len(r["ami_cleanup"].get("deregistered", [])) for r in _results)
        ami_failed       = sum(len(r["ami_cleanup"].get("failed",       [])) for r in _results)

        # EBS 스냅샷 정리 집계
        snap_deleted = sum(len(r["snap_cleanup"].get("deleted", [])) for r in _results)
        snap_failed  = sum(len(r["snap_cleanup"].get("failed",  [])) for r in _results)

        if iam_deleted or iam_failed:
            lines += [
                f"  ─────────────────────────────────────",
                f"  IAM 사용자 정리 현황",
                f"    · 삭제 완료          : {iam_deleted}명",
            ]
            if iam_failed:
                lines.append(f"    · 삭제 실패          : {iam_failed}명")

        if ami_deregistered or ami_failed:
            lines += [
                f"  ─────────────────────────────────────",
                f"  AMI 정리 현황",
                f"    · 해지 완료          : {ami_deregistered}개",
            ]
            if ami_failed:
                lines.append(f"    · 해지 실패          : {ami_failed}개")

        if snap_deleted or snap_failed:
            lines += [
                f"  ─────────────────────────────────────",
                f"  EBS 스냅샷 정리 현황",
                f"    · 삭제 완료          : {snap_deleted}개",
            ]
            if snap_failed:
                lines.append(f"    · 삭제 실패          : {snap_failed}개")

        # VPC 정리 집계
        vpc_deleted = sum(len(r["vpc_cleanup"].get("deleted", [])) for r in _results)
        vpc_failed  = sum(len(r["vpc_cleanup"].get("failed",  [])) for r in _results)

        if vpc_deleted or vpc_failed:
            lines += [
                f"  ─────────────────────────────────────",
                f"  VPC 정리 현황 (비기본 VPC, 마지막 단계)",
                f"    · 삭제 완료          : {vpc_deleted}개",
            ]
            if vpc_failed:
                lines.append(f"    · 삭제 실패          : {vpc_failed}개  (종속 리소스 잔존 가능성)")

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

    # audit 모드일 때 delete 모드 안내 문구 출력
    if not delete_mode:
        lines += [
            "",
            "  ※ 리소스를 삭제하려면 --delete 옵션을 추가해 재실행하세요.",
            "     예시: python aws-resource-audit.py --delete",
        ]

    print("\n".join(lines))


def main():
    args = parse_args()
    delete_mode = args.delete

    mode_label = "감사 + 삭제" if delete_mode else "감사"
    print(f"AWS 수강생 계정 리소스 {mode_label} 스크립트 시작...")
    if delete_mode:
        print("  ※ --delete 모드: 발견된 리소스를 실제로 삭제합니다.")

    creds = parse_credentials(file_path=args.key_file)
    if not creds:
        print("검사할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    # --id 가 지정된 경우 해당 순번(1-based)의 계정만 추출
    if args.account_id is not None:
        idx = args.account_id
        if idx < 1 or idx > len(creds):
            print(f"오류: --id {idx} 는 유효하지 않습니다. 계정 수: {len(creds)}개 (1~{len(creds)})")
            return
        creds = [creds[idx - 1]]
        print(f"  ※ --id {idx} 모드: {creds[0][2]}만 검사합니다.")

    print(f"총 {len(creds)}개의 계정을 병렬로 검사합니다. (계정별 결과는 완료 순으로 출력)")

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = {
            executor.submit(check_aws_account, ak, sk, name, delete_mode): name
            for ak, sk, name in creds
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()
            except Exception as e:
                with _print_lock:
                    print(f"[오류] {futures[future]} 처리 중 예외 발생: {e}", flush=True)

    print_summary(len(creds), delete_mode=delete_mode)
    print("\n모든 계정 검사 완료.")

if __name__ == "__main__":
    main()