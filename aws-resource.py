import boto3
from botocore.exceptions import ClientError, NoCredentialsError, BotoCoreError
import sys
import concurrent.futures
import threading

# 검사할 리소스 목록 (Boto3 클라이언트, 리전 범위, API 호출명, 결과 키)
RESOURCE_CHECKS = {
    # === Global Services ===
    "IAM Users": ('iam', 'global', 'list_users', 'Users'),
    "CloudFront (Enabled)": ('cloudfront', 'global', 'list_distributions', 'DistributionList'),
    "WAFv2 ACLs (Global)": ('wafv2', 'global', 'list_web_acls', 'WebACLs'), # [추가] WAFv2 글로벌 (CloudFront)
    
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
            response = getattr(client, api_call)()
            users = [u for u in response.get(result_key, []) if 'AWSServiceRole' not in u.get('Arn', '')]
            if users:
                user_names = [u['UserName'] for u in users]
                return f"IAM 사용자 {len(users)}명 발견: {', '.join(user_names)}"
        
        # === [필터링] CloudFront (Enabled) ===
        elif resource_name == 'CloudFront (Enabled)':
            response = getattr(client, api_call)()
            distribution_list = response.get(result_key, {})
            enabled_dists = [d for d in distribution_list.get('Items', []) if d.get('Enabled') == True]
            if enabled_dists:
                return f"{resource_name} 리소스 {len(enabled_dists)}개 발견 (글로벌)"
        
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
        
        # === [추가] WAFv2 ACLs (Global/CloudFront) ===
        elif resource_name == 'WAFv2 ACLs (Global)':
            # 'global' scope (CLOUDFRONT)로 API 호출
            # (참고: 이 서비스는 'us-east-1' 리전 클라이언트를 사용해야 하며, 
            # 메인 로직에서 'global' 서비스는 'us-east-1'로만 호출하도록 이미 처리되어 있음)
            response = client.list_web_acls(Scope='CLOUDFRONT')
            resources = response.get(result_key, [])
            if resources:
                return f"{resource_name} 리소스 {len(resources)}개 발견 (글로벌)"
        
        # === [추가] WAFv2 ACLs (Regional) ===
        elif resource_name == 'WAFv2 ACLs (Regional)':
            # 'regional' scope로 API 호출
            response = client.list_web_acls(Scope='REGIONAL')
            resources = response.get(result_key, [])
            if resources:
                return f"{resource_name} 리소스 {len(resources)}개 발견 (리전: {region})"

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

def get_enabled_regions(session):
    """활성화된 모든 리전 목록을 반환"""
    try:
        ec2_client = session.client('ec2', region_name='us-east-1')
        regions = ec2_client.describe_regions(
            Filters=[{'Name': 'opt-in-status', 'Values': ['opted-in', 'opt-in-not-required']}]
        )
        return [r['RegionName'] for r in regions['Regions']]
    except ClientError as e:
        print(f"  [오류] 리전 목록을 가져오는 중 에러 발생: {e}")
        print("  >> Access Key가 유효한지, 'ec2:DescribeRegions' 권한이 있는지 확인하세요.")
        return None

def check_aws_account(access_key, secret_key, account_name):
    """
    단일 AWS 계정의 리소스를 (병렬로) 검사
    (메인 스레드에서 계정별로 순차 실행됨)
    """
    print(f"\n--- [{account_name} / Key: {access_key[:5]}...] 계정 검사 시작 ---")
    
    try:
        session = boto3.Session(
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key
        )
    except Exception as e:
        print(f"  [오류] Boto3 세션 생성 실패: {e}")
        return

    enabled_regions = get_enabled_regions(session)
    if not enabled_regions:
        print(f"--- [{account_name}] 계정 검사 중단 (리전 정보 없음) ---")
        return

    warnings_found = []
    
    # === [수정됨] 병렬 처리 시작 ===
    # I/O(API 호출)가 많은 작업이므로 max_workers를 넉넉하게 설정
    with concurrent.futures.ThreadPoolExecutor(max_workers=30) as executor:
        futures = []
        
        # 1. 모든 (서비스, 리전) 조합을 작업(future)으로 제출
        for resource_name, config in RESOURCE_CHECKS.items():
            service_client, scope, api_call, result_key = config
            
            if scope == 'global':
                # 글로벌 서비스는 'us-east-1' 기준으로 한 번 제출
                futures.append(executor.submit(
                    check_single_service, session, resource_name, config, 'us-east-1'
                ))
            
            elif scope == 'regional':
                # 리전별 서비스는 활성화된 모든 리전에 대해 제출
                for region in enabled_regions:
                    futures.append(executor.submit(
                        check_single_service, session, resource_name, config, region
                    ))
        
        # 2. 완료되는 작업부터 결과 수집
        for future in concurrent.futures.as_completed(futures):
            try:
                result_warning = future.result()
                if result_warning:
                    warnings_found.append(result_warning)
            except Exception as e:
                # 개별 작업 실패 (거의 발생 안 함)
                print(f"  [오류] 개별 서비스 검사 중 에러: {e}")
    
    # === 병렬 처리 종료 ===

    # --- 최종 결과 출력 ---
    if warnings_found:
        print(f"  [경고] 다음 리소스가 발견되었습니다:")
        # 정렬하여 출력 (순서가 섞이는 것을 방지)
        for warning in sorted(list(set(warnings_found))): 
            print(f"    - {warning}")
    else:
        print("  [성공] 계정이 깨끗합니다. 발견된 주요 리소스가 없습니다.")
    
    print(f"--- [{account_name}] 계정 검사 완료 ---")


def main():
    print("AWS 수강생 계정 리소스 (병렬) 검사 스크립트 시작...")
    
    creds = parse_credentials()
    if not creds:
        print("검사할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    print(f"총 {len(creds)}개의 계정을 검사합니다.")
    
    # [참고] 계정 간에는 API Throttling(호출 제한)을 피하기 위해
    #        안전하게 '순차적'으로 실행합니다. (계정 내부 검사만 병렬 실행)
    for access_key, secret_key, account_name in creds:
        check_aws_account(access_key, secret_key, account_name)

if __name__ == "__main__":
    main()