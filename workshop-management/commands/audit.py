# =============================================================================
# commands/audit.py
# awsw audit — 잔여 리소스 스캔 (읽기 전용)
# awsw clean — 잔여 리소스 스캔 후 삭제
#
# 기존 aws-resource-audit.py 의 로직을 click 커맨드로 래핑한다.
# =============================================================================
from __future__ import annotations

import concurrent.futures
import time
from datetime import date, timedelta
from functools import partial

import click
from botocore.exceptions import BotoCoreError, ClientError

from utils.credentials import filter_credentials, load_credentials
from utils.output import account_sort_key, clear_results, flush_log, get_results, record_result, set_current_account
from utils.parallel import run_parallel
from utils.session import make_session

# ── 감사 대상 리소스 목록 ─────────────────────────────────────────────────────
# (서비스 클라이언트, 범위, API 메서드명, 결과 키)
RESOURCE_CHECKS = {
    # 글로벌 서비스
    "IAM Users":              ("iam",            "global",   "list_users",                    "Users"),
    "CloudFront":             ("cloudfront",      "global",   "list_distributions",            "DistributionList"),
    "WAFv2 ACLs (Global)":    ("wafv2",           "global",   "list_web_acls",                 "WebACLs"),
    "Route53 Hosted Zones":   ("route53",         "global",   "list_hosted_zones",             "HostedZones"),
    # 리전 서비스
    "EC2 Instances":          ("ec2",             "regional", "describe_instances",            "Reservations"),
    "VPC":                    ("ec2",             "regional", "describe_vpcs",                 "Vpcs"),
    "AMI":                    ("ec2",             "regional", "describe_images",               "Images"),
    "EBS Snapshots":          ("ec2",             "regional", "describe_snapshots",            "Snapshots"),
    "EBS Volumes":            ("ec2",             "regional", "describe_volumes",              "Volumes"),
    "EIP":                    ("ec2",             "regional", "describe_addresses",            "Addresses"),
    "AutoScalingGroups":      ("autoscaling",     "regional", "describe_auto_scaling_groups",  "AutoScalingGroups"),
    "KMS Keys (Disabled CMK)":("kms",             "regional", "list_keys",                     "Keys"),
    "ELB (v1)":               ("elb",             "regional", "describe_load_balancers",       "LoadBalancerDescriptions"),
    "ELB (v2)":               ("elbv2",           "regional", "describe_load_balancers",       "LoadBalancers"),
    "EKS Clusters":           ("eks",             "regional", "list_clusters",                 "clusters"),
    "Lambda":                 ("lambda",           "regional", "list_functions",               "Functions"),
    "SecretManager":          ("secretsmanager",  "regional", "list_secrets",                  "SecretList"),
    "RDS":                    ("rds",             "regional", "describe_db_instances",         "DBInstances"),
    "RDS Snapshots":          ("rds",             "regional", "describe_db_snapshots",         "DBSnapshots"),
    "RDS Cluster Snapshots":  ("rds",             "regional", "describe_db_cluster_snapshots", "DBClusterSnapshots"),
    "ECS Clusters":           ("ecs",             "regional", "list_clusters",                 "clusterArns"),
    "ECR Repos":              ("ecr",             "regional", "describe_repositories",         "repositories"),
    "CodeBuild":              ("codebuild",       "regional", "list_projects",                 "projects"),
    "WAFv2 ACLs (Regional)":  ("wafv2",           "regional", "list_web_acls",                 "WebACLs"),
    # image-builder 모듈 리소스 — S3 버킷·CodeCommit·Image Builder 파이프라인/레시피/컴포넌트/설정
    "S3 Buckets":                  ("s3",           "global",   "list_buckets",                               "Buckets"),
    "CodeCommit":                  ("codecommit",   "regional", "list_repositories",                          "repositories"),
    "Image Builder Images":        ("imagebuilder", "regional", "list_images",                                "imageVersionList"),
    "Image Builder Pipelines":     ("imagebuilder", "regional", "list_image_pipelines",                       "imagePipelineList"),
    "Image Builder Recipes":       ("imagebuilder", "regional", "list_image_recipes",                         "imageRecipeSummaryList"),
    "Image Builder Components":    ("imagebuilder", "regional", "list_components",                            "componentVersionList"),
    "Image Builder Infra Configs": ("imagebuilder", "regional", "list_infrastructure_configurations",         "infrastructureConfigurationSummaryList"),
    "Image Builder Dist Configs":  ("imagebuilder", "regional", "list_distribution_configurations",           "distributionConfigurationSummaryList"),
    # API Gateway
    "API Gateway (REST)":          ("apigateway",   "regional", "get_rest_apis",                               "items"),
    "API Gateway (HTTP/WebSocket)": ("apigatewayv2", "regional", "get_apis",                                   "Items"),
    # IAM (추가)
    "IAM Roles (Custom)":          ("iam",          "global",   "list_roles",                                  "Roles"),
    "IAM Policies (Custom)":       ("iam",          "global",   "list_policies",                               "Policies"),
    # CloudWatch Logs
    "CloudWatch Log Groups":       ("logs",         "regional", "describe_log_groups",                         "logGroups"),
}

EXPECTED_IAM_USERS    = {"terraform-user-0", "terraform-user-1"}
PROTECTED_IAM_POLICIES = {"TerraformWorkshop-Restricted-us-east-1"}


# ── 단일 서비스 검사 ──────────────────────────────────────────────────────────

def _check_single_service(session, resource_name: str, config: tuple, region: str) -> str | None:
    """지정된 (서비스, 리전) 조합을 검사하고 발견 시 경고 문자열을 반환한다."""
    service_client, scope, api_call, result_key = config
    try:
        client = session.client(service_client, region_name=region)

        if resource_name == "IAM Users":
            users = [u for u in client.list_users().get(result_key, [])
                     if "AWSServiceRole" not in u.get("Arn", "")
                     and u.get("UserName") not in EXPECTED_IAM_USERS]
            if users:
                return f"IAM 사용자 {len(users)}명 발견: {', '.join(u['UserName'] for u in users)}"

        elif resource_name == "CloudFront":
            all_dists = client.list_distributions().get(result_key, {}).get("Items", [])
            if all_dists:
                enabled  = sum(1 for d in all_dists if d.get("Enabled"))
                disabled = len(all_dists) - enabled
                parts = ([f"활성화 {enabled}개"] if enabled else []) + ([f"비활성화 {disabled}개"] if disabled else [])
                return f"CloudFront 리소스 {len(all_dists)}개 발견 (글로벌) — {', '.join(parts)}"

        elif resource_name == "KMS Keys (Disabled CMK)":
            keys = client.list_keys().get(result_key, [])
            disabled = [k for k in keys if _kms_is_disabled_customer_key(client, k["KeyId"])]
            if disabled:
                return f"{resource_name} 리소스 {len(disabled)}개 발견 (리전: {region})"

        elif resource_name == "WAFv2 ACLs (Global)":
            resources = client.list_web_acls(Scope="CLOUDFRONT").get(result_key, [])
            if resources:
                return (f"[비용주의] {resource_name} 리소스 {len(resources)}개 발견 (글로벌)"
                        f" → {', '.join(r['Name'] for r in resources)}")

        elif resource_name == "WAFv2 ACLs (Regional)":
            resources = client.list_web_acls(Scope="REGIONAL").get(result_key, [])
            if resources:
                return (f"[비용주의] {resource_name} 리소스 {len(resources)}개 발견 (리전: {region})"
                        f" → {', '.join(r['Name'] for r in resources)}")

        elif resource_name == "Route53 Hosted Zones":
            zones = client.list_hosted_zones().get(result_key, [])
            if zones:
                public  = [z["Name"].rstrip(".") for z in zones if not z.get("Config", {}).get("PrivateZone")]
                private = [z["Name"].rstrip(".") for z in zones if z.get("Config", {}).get("PrivateZone")]
                detail = (["퍼블릭: " + ", ".join(public)] if public else []) + \
                         (["프라이빗: " + ", ".join(private)] if private else [])
                return f"[비용주의] {resource_name} {len(zones)}개 발견 (글로벌) → {' / '.join(detail)}"

        elif resource_name == "AMI":
            images = client.describe_images(Owners=["self"]).get(result_key, [])
            if images:
                return f"{resource_name} 리소스 {len(images)}개 발견 (리전: {region})"

        elif resource_name == "EBS Snapshots":
            snaps = client.describe_snapshots(OwnerIds=["self"]).get(result_key, [])
            if snaps:
                return f"{resource_name} 리소스 {len(snaps)}개 발견 (리전: {region})"

        elif resource_name == "RDS Snapshots":
            snaps = client.describe_db_snapshots(SnapshotType="manual").get(result_key, [])
            if snaps:
                ids = [s["DBSnapshotIdentifier"] for s in snaps]
                return (f"[비용주의] {resource_name} 리소스 {len(snaps)}개 발견 (리전: {region})"
                        f" → {', '.join(ids)}")

        elif resource_name == "RDS Cluster Snapshots":
            snaps = client.describe_db_cluster_snapshots(SnapshotType="manual").get(result_key, [])
            if snaps:
                ids = [s["DBClusterSnapshotIdentifier"] for s in snaps]
                return (f"[비용주의] {resource_name} 리소스 {len(snaps)}개 발견 (리전: {region})"
                        f" → {', '.join(ids)}")

        elif resource_name == "VPC":
            vpcs = client.describe_vpcs(
                Filters=[{"Name": "is-default", "Values": ["false"]}]
            ).get(result_key, [])
            if vpcs:
                return f"{resource_name} 리소스 {len(vpcs)}개 발견 (리전: {region})"

        elif resource_name == "EC2 Instances":
            reservations = client.describe_instances(Filters=[
                {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]}
            ]).get(result_key, [])
            if reservations:
                return f"{resource_name} 리소스 {len(reservations)}개 발견 (리전: {region})"

        elif resource_name == "S3 Buckets":
            # S3는 글로벌 API — 모든 버킷을 한 번에 조회
            buckets = client.list_buckets().get(result_key, [])
            if buckets:
                return f"[비용주의] {resource_name} 리소스 {len(buckets)}개 발견 (글로벌)"

        elif resource_name == "Image Builder Images":
            # 자신이 소유한 이미지(빌드 결과물)만 대상 — 파이프라인 실행으로 생성된 AMI 빌드 결과
            resources = client.list_images(owner="Self").get(result_key, [])
            if resources:
                return f"{resource_name} 리소스 {len(resources)}개 발견 (리전: {region})"

        elif resource_name == "Image Builder Recipes":
            # 자신이 소유한 레시피만 대상 (AWS 관리 레시피 제외)
            resources = client.list_image_recipes(owner="Self").get(result_key, [])
            if resources:
                return f"{resource_name} 리소스 {len(resources)}개 발견 (리전: {region})"

        elif resource_name == "Image Builder Components":
            # 자신이 소유한 컴포넌트만 대상 (AWS 관리 컴포넌트 제외)
            resources = client.list_components(owner="Self").get(result_key, [])
            if resources:
                return f"{resource_name} 리소스 {len(resources)}개 발견 (리전: {region})"

        elif resource_name == "IAM Roles (Custom)":
            # 서비스 연결 역할(service-linked role) 및 AWS 관리형 역할 제외
            roles = [r for r in client.list_roles().get(result_key, [])
                     if not r.get("Path", "").startswith("/aws-service-role/")
                     and "AWSServiceRole" not in r.get("RoleName", "")]
            if roles:
                return f"IAM 역할 {len(roles)}개 발견: {', '.join(r['RoleName'] for r in roles)}"

        elif resource_name == "IAM Policies (Custom)":
            # Scope=Local → 고객 관리형 정책만 조회 (AWS 관리형 및 보호 정책 제외)
            policies = [p for p in client.list_policies(Scope="Local").get(result_key, [])
                        if p["PolicyName"] not in PROTECTED_IAM_POLICIES]
            if policies:
                return f"IAM 정책 {len(policies)}개 발견: {', '.join(p['PolicyName'] for p in policies)}"

        else:
            resources = getattr(client, api_call)().get(result_key, [])
            if resources:
                return f"{resource_name} 리소스 {len(resources)}개 발견 (리전: {region})"

    except (ClientError, BotoCoreError):
        pass
    return None


def _kms_is_disabled_customer_key(client, key_id: str) -> bool:
    try:
        meta = client.describe_key(KeyId=key_id).get("KeyMetadata", {})
        return meta.get("KeyManager") == "CUSTOMER" and meta.get("KeyState") == "Disabled"
    except ClientError:
        return False


# ── 삭제 헬퍼 함수들 ──────────────────────────────────────────────────────────

def _force_delete_iam_user(iam, username: str, log: list) -> None:
    """IAM 사용자 삭제 전 종속 리소스를 모두 제거한 뒤 삭제한다."""
    for key in iam.list_access_keys(UserName=username).get("AccessKeyMetadata", []):
        iam.delete_access_key(UserName=username, AccessKeyId=key["AccessKeyId"])
    try:
        iam.delete_login_profile(UserName=username)
    except iam.exceptions.NoSuchEntityException:
        pass
    for mfa in iam.list_mfa_devices(UserName=username).get("MFADevices", []):
        iam.deactivate_mfa_device(UserName=username, SerialNumber=mfa["SerialNumber"])
        try:
            iam.delete_virtual_mfa_device(SerialNumber=mfa["SerialNumber"])
        except ClientError:
            pass
    for cert in iam.list_signing_certificates(UserName=username).get("Certificates", []):
        iam.delete_signing_certificate(UserName=username, CertificateId=cert["CertificateId"])
    for key in iam.list_ssh_public_keys(UserName=username).get("SSHPublicKeys", []):
        iam.delete_ssh_public_key(UserName=username, SSHPublicKeyId=key["SSHPublicKeyId"])
    for group in iam.list_groups_for_user(UserName=username).get("Groups", []):
        iam.remove_user_from_group(GroupName=group["GroupName"], UserName=username)
    for policy in iam.list_attached_user_policies(UserName=username).get("AttachedPolicies", []):
        iam.detach_user_policy(UserName=username, PolicyArn=policy["PolicyArn"])
    for pname in iam.list_user_policies(UserName=username).get("PolicyNames", []):
        iam.delete_user_policy(UserName=username, PolicyName=pname)
    iam.delete_user(UserName=username)
    log.append(f"  [IAM 정리] 사용자 삭제 완료: {username}")


def _force_delete_iam_role(iam, role_name: str, log: list) -> None:
    """IAM 역할 삭제 전 종속 리소스(인스턴스 프로파일·정책·인라인 정책)를 모두 제거한다."""
    # 인스턴스 프로파일 분리
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
            iam.delete_instance_profile(InstanceProfileName=profile_name)
        except ClientError:
            pass
    # 관리형 정책 분리
    try:
        attached = iam.list_attached_role_policies(RoleName=role_name).get("AttachedPolicies", [])
    except ClientError:
        attached = []
    for policy in attached:
        try:
            iam.detach_role_policy(RoleName=role_name, PolicyArn=policy["PolicyArn"])
        except ClientError:
            pass
    # 인라인 정책 삭제
    try:
        policy_names = iam.list_role_policies(RoleName=role_name).get("PolicyNames", [])
    except ClientError:
        policy_names = []
    for pname in policy_names:
        try:
            iam.delete_role_policy(RoleName=role_name, PolicyName=pname)
        except ClientError:
            pass
    iam.delete_role(RoleName=role_name)
    log.append(f"  [IAM 정리] 역할 삭제 완료: {role_name}")


def _force_delete_iam_policy(iam, policy_arn: str, policy_name: str, log: list) -> None:
    """고객 관리형 IAM 정책을 모든 엔티티에서 분리한 뒤 삭제한다."""
    # 모든 연결 엔티티에서 분리
    try:
        entities = iam.list_entities_for_policy(PolicyArn=policy_arn)
    except ClientError:
        entities = {}
    for user in entities.get("PolicyUsers", []):
        try:
            iam.detach_user_policy(UserName=user["UserName"], PolicyArn=policy_arn)
        except ClientError:
            pass
    for group in entities.get("PolicyGroups", []):
        try:
            iam.detach_group_policy(GroupName=group["GroupName"], PolicyArn=policy_arn)
        except ClientError:
            pass
    for role in entities.get("PolicyRoles", []):
        try:
            iam.detach_role_policy(RoleName=role["RoleName"], PolicyArn=policy_arn)
        except ClientError:
            pass
    # 비기본 버전 삭제
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
    iam.delete_policy(PolicyArn=policy_arn)
    log.append(f"  [IAM 정리] 정책 삭제 완료: {policy_name}")


def _perform_iam_cleanup(session, log: list) -> dict:
    iam = session.client("iam")
    result: dict = {"deleted": [], "failed": []}

    # ── 사용자 삭제 ──
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

    # ── 역할 삭제 (서비스 연결 역할 제외) ──
    try:
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
            _force_delete_iam_role(iam, role_name, log)
            result["deleted"].append(role_name)
        except ClientError as e:
            log.append(f"  [IAM 정리] 역할 삭제 실패 ({role_name}): {e}")
            result["failed"].append(role_name)

    # ── 고객 관리형 정책 삭제 ──
    try:
        policies = iam.list_policies(Scope="Local").get("Policies", [])
    except ClientError as e:
        log.append(f"  [IAM 정리] 정책 목록 조회 실패: {e}")
        policies = []
    for policy in policies:
        policy_arn  = policy["Arn"]
        policy_name = policy["PolicyName"]
        if policy_name in PROTECTED_IAM_POLICIES:
            log.append(f"  [IAM 정리] 보호된 정책 — 스킵: {policy_name}")
            continue
        try:
            _force_delete_iam_policy(iam, policy_arn, policy_name, log)
            result["deleted"].append(policy_name)
        except ClientError as e:
            log.append(f"  [IAM 정리] 정책 삭제 실패 ({policy_name}): {e}")
            result["failed"].append(policy_name)

    return result


def _perform_cloudfront_cleanup(session, log: list) -> dict:
    cf = session.client("cloudfront")
    result: dict = {"deleted": [], "disabled": [], "skipped": [], "failed": []}
    try:
        all_dists = []
        for page in cf.get_paginator("list_distributions").paginate():
            all_dists.extend(page.get("DistributionList", {}).get("Items", []))
    except ClientError as e:
        log.append(f"  [CloudFront 정리] 목록 조회 실패: {e}")
        return result
    for dist in all_dists:
        dist_id, enabled, status = dist["Id"], dist.get("Enabled", False), dist.get("Status", "")
        domain = dist.get("DomainName", "")
        if status == "InProgress":
            log.append(f"  [CloudFront 정리] 배포 진행 중 — 스킵: {dist_id}")
            result["skipped"].append(dist_id)
            continue
        if enabled:
            try:
                cfg_resp = cf.get_distribution_config(Id=dist_id)
                cfg = cfg_resp["DistributionConfig"]
                cfg["Enabled"] = False
                cf.update_distribution(Id=dist_id, DistributionConfig=cfg, IfMatch=cfg_resp["ETag"])
                log.append(f"  [CloudFront 정리] 비활성화 요청 완료: {dist_id} ({domain})")
                result["disabled"].append(dist_id)
            except ClientError as e:
                log.append(f"  [CloudFront 정리] 비활성화 실패 {dist_id}: {e}")
                result["failed"].append(dist_id)
        else:
            try:
                etag = cf.get_distribution(Id=dist_id)["ETag"]
                cf.delete_distribution(Id=dist_id, IfMatch=etag)
                log.append(f"  [CloudFront 정리] 삭제 완료: {dist_id} ({domain})")
                result["deleted"].append(dist_id)
            except ClientError as e:
                log.append(f"  [CloudFront 정리] 삭제 실패 {dist_id}: {e}")
                result["failed"].append(dist_id)
    return result


def _perform_ami_cleanup(session, log: list, regions: list) -> dict:
    result: dict = {"deregistered": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            for image in ec2.describe_images(Owners=["self"]).get("Images", []):
                image_id = image["ImageId"]
                try:
                    ec2.deregister_image(ImageId=image_id)
                    log.append(f"  [AMI 정리] 해지 완료: {image_id} (리전: {region})")
                    result["deregistered"].append(image_id)
                except ClientError as e:
                    log.append(f"  [AMI 정리] 해지 실패 ({image_id}): {e}")
                    result["failed"].append(image_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_ebs_snapshot_cleanup(session, log: list, regions: list) -> dict:
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            for snap in ec2.describe_snapshots(OwnerIds=["self"]).get("Snapshots", []):
                snap_id = snap["SnapshotId"]
                try:
                    ec2.delete_snapshot(SnapshotId=snap_id)
                    log.append(f"  [스냅샷 정리] 삭제 완료: {snap_id} (리전: {region})")
                    result["deleted"].append(snap_id)
                except ClientError as e:
                    log.append(f"  [스냅샷 정리] 삭제 실패 ({snap_id}): {e}")
                    result["failed"].append(snap_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_rds_snapshot_cleanup(session, log: list, regions: list) -> dict:
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            rds = session.client("rds", region_name=region)
            for snap in rds.describe_db_snapshots(SnapshotType="manual").get("DBSnapshots", []):
                snap_id = snap["DBSnapshotIdentifier"]
                try:
                    rds.delete_db_snapshot(DBSnapshotIdentifier=snap_id)
                    log.append(f"  [RDS 스냅샷 정리] DB 스냅샷 삭제 완료: {snap_id} (리전: {region})")
                    result["deleted"].append(snap_id)
                except ClientError as e:
                    log.append(f"  [RDS 스냅샷 정리] DB 스냅샷 삭제 실패 ({snap_id}): {e}")
                    result["failed"].append(snap_id)
            for snap in rds.describe_db_cluster_snapshots(SnapshotType="manual").get("DBClusterSnapshots", []):
                snap_id = snap["DBClusterSnapshotIdentifier"]
                try:
                    rds.delete_db_cluster_snapshot(DBClusterSnapshotIdentifier=snap_id)
                    log.append(f"  [RDS 스냅샷 정리] 클러스터 스냅샷 삭제 완료: {snap_id} (리전: {region})")
                    result["deleted"].append(snap_id)
                except ClientError as e:
                    log.append(f"  [RDS 스냅샷 정리] 클러스터 스냅샷 삭제 실패 ({snap_id}): {e}")
                    result["failed"].append(snap_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_lambda_cleanup(session, log: list, regions: list) -> dict:
    """모든 Lambda 함수를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            lam = session.client("lambda", region_name=region)
            functions = lam.list_functions().get("Functions", [])
            for fn in functions:
                fn_name = fn["FunctionName"]
                try:
                    lam.delete_function(FunctionName=fn_name)
                    log.append(f"  [Lambda 정리] 삭제 완료: {fn_name} (리전: {region})")
                    result["deleted"].append(fn_name)
                except ClientError as e:
                    log.append(f"  [Lambda 정리] 삭제 실패 ({fn_name}): {e}")
                    result["failed"].append(fn_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_eip_cleanup(session, log: list, regions: list) -> dict:
    """EC2 인스턴스 종료 후 남은 EIP를 해제한다.
    NAT Gateway에 연결된 EIP는 건너뜀 — _perform_vpc_cleanup에서 NAT GW 삭제 후 처리한다."""
    result: dict = {"released": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            addresses = ec2.describe_addresses().get("Addresses", [])
            for addr in addresses:
                alloc_id = addr.get("AllocationId")
                assoc_id = addr.get("AssociationId")
                eni_id    = addr.get("NetworkInterfaceId")
                if not alloc_id:
                    continue
                # NAT GW에 연결된 EIP인지 확인 — NAT GW ENI는 InterfaceType이 "nat_gateway"
                if eni_id:
                    try:
                        eni_type = ec2.describe_network_interfaces(
                            NetworkInterfaceIds=[eni_id]
                        )["NetworkInterfaces"][0].get("InterfaceType", "")
                        if eni_type == "nat_gateway":
                            log.append(f"  [EIP 정리] NAT GW EIP는 VPC 정리 단계에서 처리: {alloc_id}")
                            continue
                    except ClientError:
                        pass
                try:
                    # 인스턴스 등에 연결된 경우 먼저 분리 후 해제
                    if assoc_id:
                        ec2.disassociate_address(AssociationId=assoc_id)
                    ec2.release_address(AllocationId=alloc_id)
                    log.append(f"  [EIP 정리] 해제 완료: {alloc_id} (리전: {region})")
                    result["released"].append(alloc_id)
                except ClientError as e:
                    log.append(f"  [EIP 정리] 해제 실패 ({alloc_id}): {e}")
                    result["failed"].append(alloc_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_ec2_cleanup(session, log: list, regions: list) -> dict:
    """EC2 인스턴스를 종료(terminate)하고 완전히 종료될 때까지 대기한다.
    EBS 볼륨·VPC 삭제보다 먼저 실행해야 한다."""
    result: dict = {"terminated": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            # 종료 전 상태의 인스턴스만 대상으로 조회
            reservations = ec2.describe_instances(Filters=[
                {"Name": "instance-state-name",
                 "Values": ["pending", "running", "stopping", "stopped"]}
            ]).get("Reservations", [])
            instance_ids = [i["InstanceId"] for r in reservations for i in r["Instances"]]
            if not instance_ids:
                continue
            try:
                ec2.terminate_instances(InstanceIds=instance_ids)
                log.append(f"  [EC2 정리] 종료 요청 완료 ({len(instance_ids)}개, 리전: {region}): "
                           f"{', '.join(instance_ids)}")
                # 종료 완료까지 대기 — EBS 볼륨이 available 상태로 전환돼야 삭제 가능
                waiter = ec2.get_waiter("instance_terminated")
                waiter.wait(
                    InstanceIds=instance_ids,
                    WaiterConfig={"Delay": 10, "MaxAttempts": 30},
                )
                for iid in instance_ids:
                    log.append(f"  [EC2 정리] 종료 확인: {iid} (리전: {region})")
                    result["terminated"].append(iid)
            except ClientError as e:
                log.append(f"  [EC2 정리] 종료 실패 (리전: {region}): {e}")
                result["failed"].extend(instance_ids)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_ebs_volume_cleanup(session, log: list, regions: list) -> dict:
    """available 상태의 EBS 볼륨을 삭제한다.
    EC2 인스턴스가 종료된 후에 실행해야 한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            # 인스턴스에 연결되지 않은 볼륨만 삭제 가능
            volumes = ec2.describe_volumes(
                Filters=[{"Name": "status", "Values": ["available"]}]
            ).get("Volumes", [])
            for vol in volumes:
                vol_id = vol["VolumeId"]
                try:
                    ec2.delete_volume(VolumeId=vol_id)
                    log.append(f"  [EBS 정리] 볼륨 삭제 완료: {vol_id} (리전: {region})")
                    result["deleted"].append(vol_id)
                except ClientError as e:
                    log.append(f"  [EBS 정리] 볼륨 삭제 실패 ({vol_id}): {e}")
                    result["failed"].append(vol_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_vpc_cleanup(session, log: list, regions: list) -> dict:
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            vpcs = ec2.describe_vpcs(
                Filters=[{"Name": "is-default", "Values": ["false"]}]
            ).get("Vpcs", [])
            for vpc in vpcs:
                vpc_id = vpc["VpcId"]
                try:
                    # NAT Gateway 삭제 — 서브넷 삭제 전에 먼저 제거해야 서브넷이 지워짐
                    nat_gws = ec2.describe_nat_gateways(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]},
                                 {"Name": "state", "Values": ["available", "pending"]}]
                    ).get("NatGateways", [])
                    if nat_gws:
                        nat_ids = [n["NatGatewayId"] for n in nat_gws]
                        for nat_id in nat_ids:
                            ec2.delete_nat_gateway(NatGatewayId=nat_id)
                        # NAT GW가 완전히 삭제될 때까지 대기 (EIP 해제 가능 상태가 돼야 함)
                        waiter = ec2.get_waiter("nat_gateway_deleted")
                        waiter.wait(
                            NatGatewayIds=nat_ids,
                            WaiterConfig={"Delay": 10, "MaxAttempts": 30},
                        )
                        # NAT GW에 연결됐던 EIP 해제
                        for nat in nat_gws:
                            for addr in nat.get("NatGatewayAddresses", []):
                                alloc_id = addr.get("AllocationId")
                                if alloc_id:
                                    try:
                                        ec2.release_address(AllocationId=alloc_id)
                                        log.append(f"  [VPC 정리] NAT GW EIP 해제: {alloc_id} (리전: {region})")
                                    except ClientError:
                                        pass
                        log.append(f"  [VPC 정리] NAT Gateway 삭제 완료 ({len(nat_ids)}개, 리전: {region})")
                    # IGW 분리/삭제
                    for igw in ec2.describe_internet_gateways(
                        Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
                    ).get("InternetGateways", []):
                        ec2.detach_internet_gateway(InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc_id)
                        ec2.delete_internet_gateway(InternetGatewayId=igw["InternetGatewayId"])
                    # VPC 엔드포인트 삭제
                    eps = ec2.describe_vpc_endpoints(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]},
                                 {"Name": "vpc-endpoint-state", "Values": ["available", "pending"]}]
                    ).get("VpcEndpoints", [])
                    if eps:
                        ec2.delete_vpc_endpoints(VpcEndpointIds=[ep["VpcEndpointId"] for ep in eps])
                    # 잔여 ENI 삭제 — Lambda/ALB 등이 생성한 인터페이스가 서브넷 삭제를 막음
                    # available 상태(어디에도 연결 안 된) ENI만 삭제 가능
                    for eni in ec2.describe_network_interfaces(
                        Filters=[{"Name": "vpc-id",  "Values": [vpc_id]},
                                 {"Name": "status",  "Values": ["available"]}]
                    ).get("NetworkInterfaces", []):
                        try:
                            ec2.delete_network_interface(NetworkInterfaceId=eni["NetworkInterfaceId"])
                            log.append(f"  [VPC 정리] 잔여 ENI 삭제: {eni['NetworkInterfaceId']} (리전: {region})")
                        except ClientError:
                            pass
                    # 서브넷 삭제
                    for subnet in ec2.describe_subnets(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
                    ).get("Subnets", []):
                        ec2.delete_subnet(SubnetId=subnet["SubnetId"])
                    # 비메인 라우트 테이블 삭제
                    for rt in ec2.describe_route_tables(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
                    ).get("RouteTables", []):
                        if not any(a.get("Main") for a in rt.get("Associations", [])):
                            ec2.delete_route_table(RouteTableId=rt["RouteTableId"])
                    # VPC 피어링 연결 종료 — 이 VPC가 requester 또는 accepter인 경우 모두 처리
                    for filters in [
                        [{"Name": "requester-vpc-info.vpc-id", "Values": [vpc_id]}],
                        [{"Name": "accepter-vpc-info.vpc-id",  "Values": [vpc_id]}],
                    ]:
                        for p in ec2.describe_vpc_peering_connections(
                            Filters=filters + [{"Name": "status-code",
                                                "Values": ["active", "pending-acceptance", "provisioning"]}]
                        ).get("VpcPeeringConnections", []):
                            try:
                                ec2.delete_vpc_peering_connection(
                                    VpcPeeringConnectionId=p["VpcPeeringConnectionId"])
                                log.append(f"  [VPC 정리] 피어링 연결 삭제: {p['VpcPeeringConnectionId']}")
                            except ClientError:
                                pass
                    # VPN Gateway 분리 — VGW가 연결된 채로는 VPC 삭제 불가
                    # detach_vpn_gateway는 비동기라 분리 완료까지 폴링해야 한다
                    for vgw in ec2.describe_vpn_gateways(
                        Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
                    ).get("VpnGateways", []):
                        vgw_id = vgw["VpnGatewayId"]
                        try:
                            ec2.detach_vpn_gateway(VpnGatewayId=vgw_id, VpcId=vpc_id)
                            log.append(f"  [VPC 정리] VPN Gateway 분리 요청: {vgw_id} (리전: {region})")
                        except ClientError:
                            pass
                        # 분리 완료까지 대기 (detaching → detached)
                        for _ in range(30):
                            time.sleep(5)
                            attachments = ec2.describe_vpn_gateways(
                                VpnGatewayIds=[vgw_id]
                            )["VpnGateways"][0].get("VpcAttachments", [])
                            still_attached = [
                                a for a in attachments
                                if a.get("VpcId") == vpc_id and a.get("State") != "detached"
                            ]
                            if not still_attached:
                                log.append(f"  [VPC 정리] VPN Gateway 분리 완료: {vgw_id}")
                                break
                        else:
                            log.append(f"  [VPC 정리] VPN Gateway 분리 대기 시간 초과: {vgw_id}")
                    # Egress-only IGW 삭제 (IPv6 아웃바운드 게이트웨이)
                    for eigw in ec2.describe_egress_only_internet_gateways(
                        Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
                    ).get("EgressOnlyInternetGateways", []):
                        try:
                            ec2.delete_egress_only_internet_gateway(
                                EgressOnlyInternetGatewayId=eigw["EgressOnlyInternetGatewayId"])
                        except ClientError:
                            pass
                    # 보안 그룹 간 상호 참조 규칙 제거 — SG-A↔SG-B 참조 시 삭제 불가
                    sgs = ec2.describe_security_groups(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
                    ).get("SecurityGroups", [])
                    for sg in sgs:
                        sg_id = sg["GroupId"]
                        cross_in  = [r for r in sg.get("IpPermissions",       []) if r.get("UserIdGroupPairs")]
                        cross_out = [r for r in sg.get("IpPermissionsEgress", []) if r.get("UserIdGroupPairs")]
                        if cross_in:
                            try:
                                ec2.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=cross_in)
                            except ClientError:
                                pass
                        if cross_out:
                            try:
                                ec2.revoke_security_group_egress(GroupId=sg_id, IpPermissions=cross_out)
                            except ClientError:
                                pass
                    # 비기본 보안 그룹 삭제
                    for sg in sgs:
                        if sg["GroupName"] != "default":
                            try:
                                ec2.delete_security_group(GroupId=sg["GroupId"])
                            except ClientError:
                                pass
                    # VPC 삭제
                    ec2.delete_vpc(VpcId=vpc_id)
                    log.append(f"  [VPC 정리] VPC 삭제 완료: {vpc_id} (리전: {region})")
                    result["deleted"].append(vpc_id)
                except ClientError as e:
                    log.append(f"  [VPC 정리] VPC 삭제 실패 ({vpc_id}, 리전: {region}): {e}")
                    result["failed"].append(vpc_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_cloudwatch_cleanup(session, log: list, regions: list) -> dict:
    """CloudWatch Logs 로그 그룹을 모두 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            logs_client = session.client("logs", region_name=region)
            paginator = logs_client.get_paginator("describe_log_groups")
            log_groups = []
            for page in paginator.paginate():
                log_groups.extend(page.get("logGroups", []))
            for lg in log_groups:
                lg_name = lg["logGroupName"]
                try:
                    logs_client.delete_log_group(logGroupName=lg_name)
                    log.append(f"  [CloudWatch 정리] 로그 그룹 삭제 완료: {lg_name} (리전: {region})")
                    result["deleted"].append(lg_name)
                except ClientError as e:
                    log.append(f"  [CloudWatch 정리] 로그 그룹 삭제 실패 ({lg_name}): {e}")
                    result["failed"].append(lg_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_apigateway_cleanup(session, log: list, regions: list) -> dict:
    """REST API(v1) 및 HTTP/WebSocket API(v2)를 모두 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        # REST APIs (v1)
        try:
            apigw = session.client("apigateway", region_name=region)
            rest_apis = apigw.get_rest_apis().get("items", [])
            for api in rest_apis:
                api_id = api["id"]
                try:
                    apigw.delete_rest_api(restApiId=api_id)
                    log.append(f"  [API Gateway 정리] REST API 삭제 완료: {api.get('name', api_id)} (리전: {region})")
                    result["deleted"].append(api_id)
                except ClientError as e:
                    log.append(f"  [API Gateway 정리] REST API 삭제 실패 ({api_id}): {e}")
                    result["failed"].append(api_id)
        except (ClientError, BotoCoreError):
            pass
        # HTTP/WebSocket APIs (v2)
        try:
            apigwv2 = session.client("apigatewayv2", region_name=region)
            http_apis = apigwv2.get_apis().get("Items", [])
            for api in http_apis:
                api_id = api["ApiId"]
                try:
                    apigwv2.delete_api(ApiId=api_id)
                    log.append(f"  [API Gateway 정리] HTTP/WS API 삭제 완료: {api.get('Name', api_id)} (리전: {region})")
                    result["deleted"].append(api_id)
                except ClientError as e:
                    log.append(f"  [API Gateway 정리] HTTP/WS API 삭제 실패 ({api_id}): {e}")
                    result["failed"].append(api_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_imagebuilder_cleanup(session, log: list, regions: list) -> dict:
    """Image Builder 파이프라인 → 레시피 → 컴포넌트 → 인프라 설정 → 배포 설정 순으로 삭제한다.
    파이프라인이 레시피·설정을 참조하므로 의존 순서를 지켜야 삭제가 가능하다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ib = session.client("imagebuilder", region_name=region)

            # 0단계: 이미지(빌드 결과물) 삭제 — 파이프라인 실행으로 생성된 이미지가 남아있으면
            # 파이프라인 자체를 삭제할 수 없으므로(ResourceDependencyException) 가장 먼저 제거
            for image_version in ib.list_images(owner="Self").get("imageVersionList", []):
                image_version_arn = image_version["arn"]
                try:
                    builds = ib.list_image_build_versions(
                        imageVersionArn=image_version_arn
                    ).get("imageSummaryList", [])
                    for build in builds:
                        build_arn = build["arn"]
                        try:
                            ib.delete_image(imageBuildVersionArn=build_arn)
                            log.append(f"  [Image Builder 정리] 이미지 삭제 완료: {image_version['name']} (리전: {region})")
                            result["deleted"].append(build_arn)
                        except ClientError as e:
                            log.append(f"  [Image Builder 정리] 이미지 삭제 실패 ({build_arn}): {e}")
                            result["failed"].append(build_arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 이미지 빌드 버전 조회 실패 ({image_version_arn}): {e}")
                    result["failed"].append(image_version_arn)

            # 1단계: 파이프라인 삭제 — 레시피·인프라·배포 설정을 참조하므로 가장 먼저 삭제
            for pipeline in ib.list_image_pipelines().get("imagePipelineList", []):
                arn = pipeline["arn"]
                try:
                    ib.delete_image_pipeline(imagePipelineArn=arn)
                    log.append(f"  [Image Builder 정리] 파이프라인 삭제 완료: {pipeline['name']} (리전: {region})")
                    result["deleted"].append(arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 파이프라인 삭제 실패 ({arn}): {e}")
                    result["failed"].append(arn)

            # 2단계: 레시피 삭제 — 컴포넌트를 참조하므로 컴포넌트보다 먼저 삭제
            for recipe in ib.list_image_recipes(owner="Self").get("imageRecipeSummaryList", []):
                arn = recipe["arn"]
                try:
                    ib.delete_image_recipe(imageRecipeArn=arn)
                    log.append(f"  [Image Builder 정리] 레시피 삭제 완료: {recipe['name']} (리전: {region})")
                    result["deleted"].append(arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 레시피 삭제 실패 ({arn}): {e}")
                    result["failed"].append(arn)

            # 3단계: 컴포넌트 삭제 — 버전 ARN에서 빌드 버전 목록을 조회하여 삭제
            for comp_version in ib.list_components(owner="Self").get("componentVersionList", []):
                comp_version_arn = comp_version["arn"]
                try:
                    builds = ib.list_component_build_versions(
                        componentVersionArn=comp_version_arn
                    ).get("componentSummaryList", [])
                    for build in builds:
                        build_arn = build["arn"]
                        try:
                            ib.delete_component(componentBuildVersionArn=build_arn)
                            log.append(f"  [Image Builder 정리] 컴포넌트 삭제 완료: {comp_version['name']} (리전: {region})")
                            result["deleted"].append(build_arn)
                        except ClientError as e:
                            log.append(f"  [Image Builder 정리] 컴포넌트 삭제 실패 ({build_arn}): {e}")
                            result["failed"].append(build_arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 컴포넌트 빌드 버전 조회 실패 ({comp_version_arn}): {e}")
                    result["failed"].append(comp_version_arn)

            # 4단계: 인프라 설정 삭제
            for infra in ib.list_infrastructure_configurations().get("infrastructureConfigurationSummaryList", []):
                arn = infra["arn"]
                try:
                    ib.delete_infrastructure_configuration(infrastructureConfigurationArn=arn)
                    log.append(f"  [Image Builder 정리] 인프라 설정 삭제 완료: {infra['name']} (리전: {region})")
                    result["deleted"].append(arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 인프라 설정 삭제 실패 ({arn}): {e}")
                    result["failed"].append(arn)

            # 5단계: 배포 설정 삭제
            for dist in ib.list_distribution_configurations().get("distributionConfigurationSummaryList", []):
                arn = dist["arn"]
                try:
                    ib.delete_distribution_configuration(distributionConfigurationArn=arn)
                    log.append(f"  [Image Builder 정리] 배포 설정 삭제 완료: {dist['name']} (리전: {region})")
                    result["deleted"].append(arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 배포 설정 삭제 실패 ({arn}): {e}")
                    result["failed"].append(arn)

        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_codecommit_cleanup(session, log: list, regions: list) -> dict:
    """CodeCommit 저장소를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            cc = session.client("codecommit", region_name=region)
            repos = cc.list_repositories().get("repositories", [])
            for repo in repos:
                repo_name = repo["repositoryName"]
                try:
                    cc.delete_repository(repositoryName=repo_name)
                    log.append(f"  [CodeCommit 정리] 저장소 삭제 완료: {repo_name} (리전: {region})")
                    result["deleted"].append(repo_name)
                except ClientError as e:
                    log.append(f"  [CodeCommit 정리] 저장소 삭제 실패 ({repo_name}): {e}")
                    result["failed"].append(repo_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_s3_cleanup(session, log: list) -> dict:
    """S3 버킷 내 모든 객체(버전 포함)를 먼저 삭제한 뒤 버킷을 제거한다."""
    result: dict = {"deleted": [], "failed": []}
    try:
        s3 = session.client("s3", region_name="us-east-1")
        buckets = s3.list_buckets().get("Buckets", [])
        for bucket in buckets:
            bucket_name = bucket["Name"]
            try:
                # 버킷이 속한 리전을 조회하여 해당 리전 클라이언트로 작업 — 리전 불일치 시 접근 오류 방지
                location = s3.get_bucket_location(Bucket=bucket_name).get("LocationConstraint") or "us-east-1"
                s3r = session.client("s3", region_name=location)

                # 버전 관리 여부 확인 후 객체 삭제
                try:
                    versioning_status = s3r.get_bucket_versioning(Bucket=bucket_name).get("Status", "")
                    if versioning_status in ("Enabled", "Suspended"):
                        # 버전 관리 버킷: 모든 버전과 삭제 마커를 한꺼번에 제거
                        paginator = s3r.get_paginator("list_object_versions")
                        for page in paginator.paginate(Bucket=bucket_name):
                            to_delete = (
                                [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in page.get("Versions", [])] +
                                [{"Key": m["Key"], "VersionId": m["VersionId"]} for m in page.get("DeleteMarkers", [])]
                            )
                            if to_delete:
                                s3r.delete_objects(Bucket=bucket_name, Delete={"Objects": to_delete})
                    else:
                        # 일반 버킷: 객체 목록을 페이지 단위로 조회하여 삭제
                        paginator = s3r.get_paginator("list_objects_v2")
                        for page in paginator.paginate(Bucket=bucket_name):
                            objects = [{"Key": obj["Key"]} for obj in page.get("Contents", [])]
                            if objects:
                                s3r.delete_objects(Bucket=bucket_name, Delete={"Objects": objects})
                except ClientError:
                    pass

                s3r.delete_bucket(Bucket=bucket_name)
                log.append(f"  [S3 정리] 버킷 삭제 완료: {bucket_name}")
                result["deleted"].append(bucket_name)
            except ClientError as e:
                log.append(f"  [S3 정리] 버킷 삭제 실패 ({bucket_name}): {e}")
                result["failed"].append(bucket_name)
    except (ClientError, BotoCoreError):
        pass
    return result


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def _fetch_regions(cred: dict) -> list[str]:
    """첫 번째 계정으로 활성화된 리전 목록을 한 번만 조회한다."""
    session = make_session(cred["access_key"], cred["secret_key"])
    try:
        return [r["RegionName"] for r in session.client("ec2", region_name="us-east-1").describe_regions(
            Filters=[{"Name": "opt-in-status", "Values": ["opted-in", "opt-in-not-required"]}]
        )["Regions"]]
    except ClientError as e:
        raise RuntimeError(f"리전 목록 조회 실패: {e}")


def _audit_account(cred: dict, delete_mode: bool = False) -> None:
    """단일 계정의 잔여 리소스를 병렬 스캔하고, delete_mode=True 이면 정리까지 수행한다."""
    update_fn = cred.get("_update_progress")  # 프로그레스바 갱신 콜백 (run_parallel이 주입)
    set_current_account(cred["name"])  # 지연 출력 모드에서 계정 로그 버퍼 연결
    account_name = cred["name"]
    log = ["", f"{'='*60}", f"  [{account_name} / Key: {cred['access_key'][:5]}...] 계정 검사 시작"]

    session = make_session(cred["access_key"], cred["secret_key"])

    # 계정 ID 조회 (실패해도 계속 진행)
    account_id = None
    try:
        account_id = session.client("sts").get_caller_identity()["Account"]
        log.append(f"  계정 ID: {account_id}")
    except ClientError:
        pass

    # 활성화된 리전 목록 — 호출 전에 미리 조회된 값이 있으면 재사용
    regions = cred.get("_regions")
    if not regions:
        try:
            regions = [r["RegionName"] for r in session.client("ec2", region_name="us-east-1").describe_regions(
                Filters=[{"Name": "opt-in-status", "Values": ["opted-in", "opt-in-not-required"]}]
            )["Regions"]]
        except ClientError as e:
            log += [f"  [오류] 리전 목록 조회 실패: {e}", f"{'='*60}"]
            flush_log(log)
            record_result({"name": account_name, "account_id": account_id, "status": "error",
                           "warnings": [], "cf_cleanup": {}, "iam_cleanup": {}, "ami_cleanup": {},
                           "snap_cleanup": {}, "rds_snap_cleanup": {}, "ec2_cleanup": {},
                           "ebs_cleanup": {}, "eip_cleanup": {}, "lambda_cleanup": {}, "vpc_cleanup": {},
                           "imagebuilder_cleanup": {}, "codecommit_cleanup": {}, "s3_cleanup": {}})
            return

    # 서비스별 병렬 검사
    # max_workers=10: 계정 11개 × 10 내부 스레드 = ~110개로 GIL 경쟁 완화
    warnings_found = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        # future → resource_name 맵으로 어떤 서비스가 완료됐는지 추적한다
        futures_map: dict = {}
        for resource_name, config in RESOURCE_CHECKS.items():
            _, scope, _, _ = config
            if scope == "global":
                f = executor.submit(_check_single_service, session, resource_name, config, "us-east-1")
                futures_map[f] = resource_name
            else:
                for region in regions:
                    f = executor.submit(_check_single_service, session, resource_name, config, region)
                    futures_map[f] = resource_name

        total_tasks = len(futures_map)
        completed_tasks = 0

        for future in concurrent.futures.as_completed(futures_map):
            resource_name = futures_map[future]
            try:
                if warning := future.result():
                    warnings_found.append(warning)
            except Exception as e:
                log.append(f"  [오류] 서비스 검사 중 에러: {e}")
            finally:
                completed_tasks += 1
                if update_fn:
                    pct = int(completed_tasks / total_tasks * 100)
                    update_fn(pct, f"{resource_name} 검사 중")

    # 삭제 단계 (--delete / clean 커맨드일 때만 실행)
    # 순서: Lambda → IAM/CF/AMI/스냅샷 → EC2 종료 대기 → EIP 해제 → EBS → VPC(내부에서 NAT GW 처리)
    if delete_mode:
        lambda_cleanup      = _perform_lambda_cleanup(session, log, regions)
        apigateway_cleanup  = _perform_apigateway_cleanup(session, log, regions)
        cloudwatch_cleanup  = _perform_cloudwatch_cleanup(session, log, regions)
        iam_cleanup         = _perform_iam_cleanup(session, log)
        cf_cleanup          = _perform_cloudfront_cleanup(session, log)
        ami_cleanup         = _perform_ami_cleanup(session, log, regions)
        snap_cleanup        = _perform_ebs_snapshot_cleanup(session, log, regions)
        rds_snap_cleanup    = _perform_rds_snapshot_cleanup(session, log, regions)
        imagebuilder_cleanup = _perform_imagebuilder_cleanup(session, log, regions)
        codecommit_cleanup  = _perform_codecommit_cleanup(session, log, regions)
        s3_cleanup          = _perform_s3_cleanup(session, log)
        # EC2 종료 먼저 — 종료 완료 대기 후 EIP/EBS/VPC 정리 진행
        ec2_cleanup         = _perform_ec2_cleanup(session, log, regions)
        eip_cleanup         = _perform_eip_cleanup(session, log, regions)
        ebs_cleanup         = _perform_ebs_volume_cleanup(session, log, regions)
        vpc_cleanup         = _perform_vpc_cleanup(session, log, regions)
    else:
        iam_cleanup = cf_cleanup = ami_cleanup = snap_cleanup = {}
        rds_snap_cleanup = ec2_cleanup = ebs_cleanup = {}
        eip_cleanup = lambda_cleanup = vpc_cleanup = {}
        imagebuilder_cleanup = codecommit_cleanup = s3_cleanup = {}
        apigateway_cleanup = cloudwatch_cleanup = {}

    # 정리 완료된 항목을 경고 목록에서 제외
    def _is_cleaned(w: str) -> bool:
        if not delete_mode:
            return False
        checks = [
            ("CloudFront" in w,            cf_cleanup),
            ("IAM 사용자" in w,             iam_cleanup),
            ("IAM 역할" in w,               iam_cleanup),
            ("IAM 정책" in w,               iam_cleanup),
            ("AMI" in w,                   ami_cleanup),
            ("EBS Snapshots" in w,         snap_cleanup),
            ("EBS Volumes" in w,           ebs_cleanup),
            ("EC2 Instances" in w,         ec2_cleanup),
            ("EIP" in w,                   eip_cleanup),
            ("Lambda" in w,                lambda_cleanup),
            ("API Gateway" in w,           apigateway_cleanup),
            ("CloudWatch" in w,            cloudwatch_cleanup),
            ("RDS Snapshots" in w,         rds_snap_cleanup),
            ("RDS Cluster Snapshots" in w, rds_snap_cleanup),
            ("VPC" in w,                   vpc_cleanup),
            ("Image Builder" in w,         imagebuilder_cleanup),
            ("CodeCommit" in w,            codecommit_cleanup),
            ("S3 Buckets" in w,            s3_cleanup),
        ]
        for matches, cleanup in checks:
            if matches and not cleanup.get("failed"):
                return True
        return False

    remaining = [w for w in warnings_found if not _is_cleaned(w)]

    if remaining:
        log.append(f"  [경고] 발견된 잔여 리소스 ({len(remaining)}건):")
        for w in sorted(set(remaining)):
            log.append(f"    - {w}")
    else:
        log.append("  [성공] 잔여 리소스 없음 — 계정이 깨끗합니다.")

    status = "clean" if not remaining else "has_resources"
    log += [f"  [{account_name}] 검사 완료", f"{'='*60}"]
    flush_log(log)
    record_result({"name": account_name, "account_id": account_id, "status": status,
                   "warnings": list(set(remaining)), "cf_cleanup": cf_cleanup,
                   "iam_cleanup": iam_cleanup, "ami_cleanup": ami_cleanup,
                   "snap_cleanup": snap_cleanup, "rds_snap_cleanup": rds_snap_cleanup,
                   "ec2_cleanup": ec2_cleanup, "ebs_cleanup": ebs_cleanup,
                   "eip_cleanup": eip_cleanup, "lambda_cleanup": lambda_cleanup,
                   "apigateway_cleanup": apigateway_cleanup,
                   "cloudwatch_cleanup": cloudwatch_cleanup,
                   "vpc_cleanup": vpc_cleanup, "imagebuilder_cleanup": imagebuilder_cleanup,
                   "codecommit_cleanup": codecommit_cleanup, "s3_cleanup": s3_cleanup})


# ── 삭제 전용 계정 처리 ────────────────────────────────────────────────────────

def _delete_account(cred: dict) -> None:
    """단일 계정의 잔여 리소스를 삭제한다. 스캔 없이 정리만 수행한다.
    clean 커맨드의 2단계(삭제 단계)에서 호출된다."""
    update_fn = cred.get("_update_progress")
    set_current_account(cred["name"])
    account_name = cred["name"]
    log = ["", f"{'='*60}", f"  [{account_name}] 리소스 정리 시작"]

    session = make_session(cred["access_key"], cred["secret_key"])

    # 활성화된 리전 목록 — 호출 전에 미리 조회된 값이 있으면 재사용
    regions = cred.get("_regions")
    if not regions:
        try:
            regions = [r["RegionName"] for r in session.client("ec2", region_name="us-east-1").describe_regions(
                Filters=[{"Name": "opt-in-status", "Values": ["opted-in", "opt-in-not-required"]}]
            )["Regions"]]
        except ClientError as e:
            log += [f"  [오류] 리전 목록 조회 실패: {e}", f"{'='*60}"]
            flush_log(log)
            record_result({"name": account_name, "status": "error",
                           "lambda_cleanup": {}, "apigateway_cleanup": {}, "cloudwatch_cleanup": {},
                           "iam_cleanup": {}, "cf_cleanup": {},
                           "ami_cleanup": {}, "snap_cleanup": {}, "rds_snap_cleanup": {},
                           "ec2_cleanup": {}, "eip_cleanup": {}, "ebs_cleanup": {}, "vpc_cleanup": {},
                           "imagebuilder_cleanup": {}, "codecommit_cleanup": {}, "s3_cleanup": {}})
            return

    # 감사에서 발견된 리소스 타입만 삭제 — 없는 타입은 API 호출조차 하지 않는다
    warnings = cred.get("_audit_warnings", [])
    def _found(keyword: str) -> bool:
        return any(keyword in w for w in warnings)

    should_run = {
        "lambda_cleanup":        _found("Lambda"),
        "apigateway_cleanup":    _found("API Gateway"),
        "cloudwatch_cleanup":    _found("CloudWatch"),
        "iam_cleanup":           _found("IAM"),
        "cf_cleanup":            _found("CloudFront"),
        "ami_cleanup":           _found("AMI"),
        "snap_cleanup":          _found("EBS Snapshots"),
        "rds_snap_cleanup":      _found("RDS Snapshots") or _found("RDS Cluster"),
        "imagebuilder_cleanup":  _found("Image Builder"),
        "codecommit_cleanup":    _found("CodeCommit"),
        "s3_cleanup":            _found("S3 Buckets"),
        "ec2_cleanup":           _found("EC2 Instances"),
        "eip_cleanup":           _found("EIP"),
        "ebs_cleanup":           _found("EBS Volumes"),
        "vpc_cleanup":           _found("VPC"),
    }

    # 실행할 작업만 필터링 (순서 유지: 의존 관계 반영)
    ALL_OPS = [
        ("lambda_cleanup",       lambda: _perform_lambda_cleanup(session, log, regions),        "Lambda 삭제 중"),
        ("apigateway_cleanup",   lambda: _perform_apigateway_cleanup(session, log, regions),    "API Gateway 삭제 중"),
        ("cloudwatch_cleanup",   lambda: _perform_cloudwatch_cleanup(session, log, regions),    "CloudWatch 로그 그룹 삭제 중"),
        ("iam_cleanup",          lambda: _perform_iam_cleanup(session, log),                    "IAM 정리 중"),
        ("cf_cleanup",           lambda: _perform_cloudfront_cleanup(session, log),             "CloudFront 정리 중"),
        ("ami_cleanup",          lambda: _perform_ami_cleanup(session, log, regions),           "AMI 정리 중"),
        ("snap_cleanup",         lambda: _perform_ebs_snapshot_cleanup(session, log, regions),  "EBS 스냅샷 삭제 중"),
        ("rds_snap_cleanup",     lambda: _perform_rds_snapshot_cleanup(session, log, regions),  "RDS 스냅샷 삭제 중"),
        # Image Builder 의존 순서: 파이프라인 → 레시피 → 컴포넌트 → 인프라/배포 설정
        ("imagebuilder_cleanup", lambda: _perform_imagebuilder_cleanup(session, log, regions),  "Image Builder 정리 중"),
        ("codecommit_cleanup",   lambda: _perform_codecommit_cleanup(session, log, regions),    "CodeCommit 정리 중"),
        ("s3_cleanup",           lambda: _perform_s3_cleanup(session, log),                     "S3 버킷 삭제 중"),
        ("ec2_cleanup",          lambda: _perform_ec2_cleanup(session, log, regions),           "EC2 종료 중"),
        ("eip_cleanup",          lambda: _perform_eip_cleanup(session, log, regions),           "EIP 해제 중"),
        ("ebs_cleanup",          lambda: _perform_ebs_volume_cleanup(session, log, regions),    "EBS 볼륨 삭제 중"),
        ("vpc_cleanup",          lambda: _perform_vpc_cleanup(session, log, regions),           "VPC 삭제 중"),
    ]
    active_ops = [(key, fn, label) for key, fn, label in ALL_OPS if should_run.get(key)]
    total_ops  = len(active_ops)
    cleanup_results = {key: {} for key, _, _ in ALL_OPS}  # 미실행 항목은 빈 dict

    log.append(f"  실행할 정리 작업: {', '.join(label for _, _, label in active_ops)}")

    for i, (key, op_fn, status_text) in enumerate(active_ops):
        if update_fn:
            update_fn(int(i / total_ops * 100), status_text)
        cleanup_results[key] = op_fn()

    log += [f"  [{account_name}] 정리 완료", f"{'='*60}"]
    flush_log(log)
    # imagebuilder_cleanup / codecommit_cleanup / s3_cleanup 은 미실행 시 {} 로 초기화됨
    record_result({"name": account_name, "status": "cleaned", **cleanup_results})


# ── 요약 출력 ─────────────────────────────────────────────────────────────────

def _print_audit_summary(total: int, delete_mode: bool = False) -> None:
    results  = get_results()
    clean    = [r for r in results if r["status"] == "clean"]
    has_res  = [r for r in results if r["status"] == "has_resources"]
    errors   = [r for r in results if r["status"] == "error"]
    mode_label = "감사 + 정리" if delete_mode else "감사"

    lines = ["", "=" * 60, f"  [최종 {mode_label} 요약]", "=" * 60,
             f"  전체 계정 수          : {total}개",
             f"  깨끗한 계정           : {len(clean)}개",
             f"  잔여 리소스 있음      : {len(has_res)}개",
             f"  검사 오류             : {len(errors)}개"]

    if delete_mode:
        def _sum(key, sub): return sum(len(r.get(key, {}).get(sub, [])) for r in results)
        stats = [
            ("IAM 정리",          [("삭제 완료", _sum("iam_cleanup", "deleted")),
                                   ("삭제 실패", _sum("iam_cleanup", "failed"))]),
            ("Lambda 정리",       [("삭제 완료", _sum("lambda_cleanup", "deleted")),
                                   ("삭제 실패", _sum("lambda_cleanup", "failed"))]),
            ("API Gateway 정리",  [("삭제 완료", _sum("apigateway_cleanup", "deleted")),
                                   ("삭제 실패", _sum("apigateway_cleanup", "failed"))]),
            ("CloudWatch 정리",   [("삭제 완료", _sum("cloudwatch_cleanup", "deleted")),
                                   ("삭제 실패", _sum("cloudwatch_cleanup", "failed"))]),
            ("Image Builder 정리",[("삭제 완료", _sum("imagebuilder_cleanup", "deleted")),
                                   ("삭제 실패", _sum("imagebuilder_cleanup", "failed"))]),
            ("CodeCommit 정리",   [("삭제 완료", _sum("codecommit_cleanup", "deleted")),
                                   ("삭제 실패", _sum("codecommit_cleanup", "failed"))]),
            ("S3 버킷 정리",      [("삭제 완료", _sum("s3_cleanup", "deleted")),
                                   ("삭제 실패", _sum("s3_cleanup", "failed"))]),
            ("EC2 인스턴스",      [("종료 완료", _sum("ec2_cleanup", "terminated")),
                                   ("종료 실패", _sum("ec2_cleanup", "failed"))]),
            ("EIP 정리",          [("해제 완료", _sum("eip_cleanup", "released")),
                                   ("해제 실패", _sum("eip_cleanup", "failed"))]),
            ("EBS 볼륨",          [("삭제 완료", _sum("ebs_cleanup", "deleted")),
                                   ("삭제 실패", _sum("ebs_cleanup", "failed"))]),
            ("AMI 정리",          [("해지 완료", _sum("ami_cleanup", "deregistered")),
                                   ("해지 실패", _sum("ami_cleanup", "failed"))]),
            ("EBS 스냅샷",        [("삭제 완료", _sum("snap_cleanup", "deleted")),
                                   ("삭제 실패", _sum("snap_cleanup", "failed"))]),
            ("RDS 스냅샷",        [("삭제 완료", _sum("rds_snap_cleanup", "deleted")),
                                   ("삭제 실패", _sum("rds_snap_cleanup", "failed"))]),
            ("VPC 정리",          [("삭제 완료", _sum("vpc_cleanup", "deleted")),
                                   ("삭제 실패", _sum("vpc_cleanup", "failed"))]),
            ("CloudFront",        [("삭제 완료",    _sum("cf_cleanup", "deleted")),
                                   ("비활성화 요청", _sum("cf_cleanup", "disabled")),
                                   ("실패",         _sum("cf_cleanup", "failed")),
                                   ("스킵",         _sum("cf_cleanup", "skipped"))]),
        ]
        for section, items in stats:
            if any(v for _, v in items):
                lines += [f"  ─────────────────────────────────────", f"  {section} 현황"]
                for label, val in items:
                    if val:
                        lines.append(f"    · {label:<14} : {val}개")

    if has_res:
        lines += ["", "=" * 60, "  [잔여 리소스 발견 계정]", "=" * 60]
        for r in sorted(has_res, key=account_sort_key):
            lines.append(f"  {r['name']:<10}  계정 ID: {r.get('account_id', 'N/A')}  ({len(r['warnings'])}건)")
            for w in sorted(r["warnings"]):
                lines.append(f"    └ {w}")

    needs_rerun = [r for r in results if r.get("cf_cleanup", {}).get("disabled")]
    if needs_rerun:
        lines += ["", "=" * 60, "  [CloudFront 재실행 필요 계정]", "=" * 60]
        for r in sorted(needs_rerun, key=account_sort_key):
            lines.append(f"  {r['name']:<10}  배포 ID: {', '.join(r['cf_cleanup']['disabled'])}")

    if not delete_mode:
        lines += ["", "  ※ 리소스를 삭제하려면 awsw clean 을 사용하세요."]
    lines.append("=" * 60)
    print("\n".join(lines))


def _print_delete_summary() -> None:
    """삭제 단계 결과 요약을 출력한다."""
    results = get_results()
    def _sum(key, sub): return sum(len(r.get(key, {}).get(sub, [])) for r in results)

    stats = [
        ("Lambda 정리",       [("삭제 완료", _sum("lambda_cleanup",       "deleted")),
                               ("삭제 실패", _sum("lambda_cleanup",       "failed"))]),
        ("IAM 정리",          [("삭제 완료", _sum("iam_cleanup",          "deleted")),
                               ("삭제 실패", _sum("iam_cleanup",          "failed"))]),
        ("Image Builder 정리",[("삭제 완료", _sum("imagebuilder_cleanup", "deleted")),
                               ("삭제 실패", _sum("imagebuilder_cleanup", "failed"))]),
        ("CodeCommit 정리",   [("삭제 완료", _sum("codecommit_cleanup",   "deleted")),
                               ("삭제 실패", _sum("codecommit_cleanup",   "failed"))]),
        ("S3 버킷 정리",      [("삭제 완료", _sum("s3_cleanup",           "deleted")),
                               ("삭제 실패", _sum("s3_cleanup",           "failed"))]),
        ("EC2 인스턴스",      [("종료 완료", _sum("ec2_cleanup",          "terminated")),
                               ("종료 실패", _sum("ec2_cleanup",          "failed"))]),
        ("EIP 정리",          [("해제 완료", _sum("eip_cleanup",          "released")),
                               ("해제 실패", _sum("eip_cleanup",          "failed"))]),
        ("EBS 볼륨",          [("삭제 완료", _sum("ebs_cleanup",          "deleted")),
                               ("삭제 실패", _sum("ebs_cleanup",          "failed"))]),
        ("AMI 정리",          [("해지 완료", _sum("ami_cleanup",          "deregistered")),
                               ("해지 실패", _sum("ami_cleanup",          "failed"))]),
        ("EBS 스냅샷",        [("삭제 완료", _sum("snap_cleanup",         "deleted")),
                               ("삭제 실패", _sum("snap_cleanup",         "failed"))]),
        ("RDS 스냅샷",        [("삭제 완료", _sum("rds_snap_cleanup",     "deleted")),
                               ("삭제 실패", _sum("rds_snap_cleanup",     "failed"))]),
        ("VPC 정리",          [("삭제 완료", _sum("vpc_cleanup",          "deleted")),
                               ("삭제 실패", _sum("vpc_cleanup",          "failed"))]),
        ("CloudFront",        [("삭제 완료",    _sum("cf_cleanup", "deleted")),
                               ("비활성화 요청", _sum("cf_cleanup", "disabled")),
                               ("실패",         _sum("cf_cleanup", "failed")),
                               ("스킵",         _sum("cf_cleanup", "skipped"))]),
    ]

    lines = ["", "=" * 60, "  [삭제 결과 요약]", "=" * 60]
    any_action = False
    for section, items in stats:
        if any(v for _, v in items):
            any_action = True
            lines += [f"  ─────────────────────────────────────", f"  {section} 현황"]
            for label, val in items:
                if val:
                    lines.append(f"    · {label:<14} : {val}개")

    cf_disabled = [r for r in results if r.get("cf_cleanup", {}).get("disabled")]
    if cf_disabled:
        lines += ["", "=" * 60, "  [CloudFront 재실행 필요 — 배포 비활성화만 완료]", "=" * 60]
        for r in sorted(cf_disabled, key=account_sort_key):
            lines.append(f"  {r['name']:<10}  배포 ID: {', '.join(r['cf_cleanup']['disabled'])}")

    if not any_action:
        lines.append("  삭제된 리소스 없음")
    lines.append("=" * 60)
    print("\n".join(lines))


# ── click 커맨드 ───────────────────────────────────────────────────────────────

@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
@click.option("--output", "-o", "output_fmt",
              type=click.Choice(["table", "json", "csv"]), default="table", show_default=True,
              help="출력 포맷")
@click.option("--delete", is_flag=True, help="감사 후 잔여 리소스 삭제 (clean 동작)")
@click.option("--yes", "-y", is_flag=True, help="삭제 확인 프롬프트 생략 (--delete 사용 시)")
@click.option("--dry-run", is_flag=True, help="실제 변경 없이 결과 미리 보기")
def cmd(credentials_file, account_filter, output_fmt, delete, yes, dry_run):
    """잔여 리소스 스캔 (읽기 전용). --delete 플래그로 삭제까지 수행."""
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    delete_mode = delete and not dry_run
    if delete_mode and not yes:
        click.confirm("잔여 리소스를 삭제하시겠습니까?", abort=True)

    click.echo(f"AWS 리소스 감사 시작 ({'감사 + 삭제' if delete_mode else '감사만'}) — 총 {len(creds)}개 계정\n")
    regions = _fetch_regions(creds[0])
    enriched_creds = [{**c, "_regions": regions} for c in creds]
    clear_results()
    run_parallel(partial(_audit_account, delete_mode=delete_mode), enriched_creds)
    _print_audit_summary(len(creds), delete_mode=delete_mode)
    click.echo("\n모든 계정 검사 완료.")


# clean 커맨드 — 1단계 감사 → 결과 확인 → 2단계 삭제
@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
@click.option("--yes", "-y", is_flag=True, help="삭제 확인 프롬프트 생략")
@click.option("--dry-run", is_flag=True, help="실제 변경 없이 감사 결과만 출력")
def clean_cmd(credentials_file, account_filter, yes, dry_run):
    """잔여 리소스 감사 후 확인을 받아 삭제한다. (1단계: 감사 → 확인 → 2단계: 삭제)"""
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    # ── 1단계: 감사 ──────────────────────────────────────────────────────────
    click.echo(f"\n[1단계] 잔여 리소스 감사 — 총 {len(creds)}개 계정\n")
    regions = _fetch_regions(creds[0])
    enriched_creds = [{**c, "_regions": regions} for c in creds]
    clear_results()
    run_parallel(partial(_audit_account, delete_mode=False), enriched_creds)
    _print_audit_summary(len(creds), delete_mode=False)

    # 잔여 리소스가 있는 계정만 추출 — warnings도 함께 보존해 2단계에서 선택적 삭제에 사용
    audit_results = get_results()
    dirty_map = {
        r["name"]: r["warnings"]
        for r in audit_results if r["status"] == "has_resources"
    }
    if not dirty_map:
        click.echo("\n모든 계정이 깨끗합니다. 정리할 리소스가 없습니다.")
        return

    if dry_run:
        click.echo("\n[dry-run] 실제 삭제는 수행하지 않습니다.")
        return

    # ── 삭제 확인 ────────────────────────────────────────────────────────────
    # _audit_warnings: 감사에서 발견된 경고 목록을 삭제 단계에 전달 (필요한 작업만 실행하기 위해)
    # _regions: 1단계에서 조회한 리전 목록 재사용
    dirty_creds = [
        {**c, "_audit_warnings": dirty_map[c["name"]], "_regions": regions}
        for c in creds if c["name"] in dirty_map
    ]
    if not yes:
        try:
            click.confirm(
                f"\n위 리소스를 삭제하시겠습니까? ({len(dirty_creds)}개 계정)",
                abort=True,
            )
        except click.exceptions.Abort:
            click.echo("\n취소됐습니다.")
            return

    # ── 2단계: 삭제 ──────────────────────────────────────────────────────────
    click.echo(f"\n[2단계] 리소스 삭제 — {len(dirty_creds)}개 계정\n")
    clear_results()
    run_parallel(_delete_account, dirty_creds)
    _print_delete_summary()
    click.echo("\n모든 계정 정리 완료.")
