# =============================================================================
# commands/audit.py
# awsw audit — 잔여 리소스 스캔 (읽기 전용)
# awsw clean — 잔여 리소스 스캔 후 삭제
#
# 기존 aws-resource-audit.py 의 로직을 click 커맨드로 래핑한다.
# =============================================================================
from __future__ import annotations

import concurrent.futures
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
}

EXPECTED_IAM_USERS = {"terraform-user-0", "terraform-user-1"}


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


def _perform_iam_cleanup(session, log: list) -> dict:
    iam = session.client("iam")
    result: dict = {"deleted": [], "failed": []}
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
                    # 비기본 보안 그룹 삭제
                    for sg in ec2.describe_security_groups(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
                    ).get("SecurityGroups", []):
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


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def _audit_account(cred: dict, delete_mode: bool = False) -> None:
    """단일 계정의 잔여 리소스를 병렬 스캔하고, delete_mode=True 이면 정리까지 수행한다."""
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

    # 활성화된 리전 목록 조회
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
                       "ebs_cleanup": {}, "vpc_cleanup": {}})
        return

    # 서비스별 병렬 검사
    warnings_found = []
    # max_workers를 줄여야 스피너 버벅임 없음
    # 계정 11개 × 30 내부 스레드 = 330개 스레드가 동시에 GIL 경쟁 → 스피너 스레드 스케줄 밀림
    # 10으로 줄이면 총 ~110개 수준으로 GIL 경쟁 완화
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = []
        for resource_name, config in RESOURCE_CHECKS.items():
            _, scope, _, _ = config
            if scope == "global":
                futures.append(executor.submit(_check_single_service, session, resource_name, config, "us-east-1"))
            else:
                for region in regions:
                    futures.append(executor.submit(_check_single_service, session, resource_name, config, region))
        for future in concurrent.futures.as_completed(futures):
            try:
                if warning := future.result():
                    warnings_found.append(warning)
            except Exception as e:
                log.append(f"  [오류] 서비스 검사 중 에러: {e}")

    # 삭제 단계 (--delete / clean 커맨드일 때만 실행)
    # 순서 중요: EC2 종료 → EBS 볼륨 삭제 → VPC 삭제 (의존 관계 있음)
    if delete_mode:
        iam_cleanup      = _perform_iam_cleanup(session, log)
        cf_cleanup       = _perform_cloudfront_cleanup(session, log)
        ami_cleanup      = _perform_ami_cleanup(session, log, regions)
        snap_cleanup     = _perform_ebs_snapshot_cleanup(session, log, regions)
        rds_snap_cleanup = _perform_rds_snapshot_cleanup(session, log, regions)
        # EC2 종료 먼저 — 종료 완료 대기 후 EBS/VPC 정리 진행
        ec2_cleanup      = _perform_ec2_cleanup(session, log, regions)
        ebs_cleanup      = _perform_ebs_volume_cleanup(session, log, regions)
        vpc_cleanup      = _perform_vpc_cleanup(session, log, regions)
    else:
        iam_cleanup = cf_cleanup = ami_cleanup = snap_cleanup = {}
        rds_snap_cleanup = ec2_cleanup = ebs_cleanup = vpc_cleanup = {}

    # 정리 완료된 항목을 경고 목록에서 제외
    def _is_cleaned(w: str) -> bool:
        if not delete_mode:
            return False
        checks = [
            ("CloudFront" in w,            cf_cleanup),
            ("IAM 사용자" in w,             iam_cleanup),
            ("AMI" in w,                   ami_cleanup),
            ("EBS Snapshots" in w,         snap_cleanup),
            ("EBS Volumes" in w,           ebs_cleanup),
            ("EC2 Instances" in w,         ec2_cleanup),
            ("RDS Snapshots" in w,         rds_snap_cleanup),
            ("RDS Cluster Snapshots" in w, rds_snap_cleanup),
            ("VPC" in w,                   vpc_cleanup),
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
                   "vpc_cleanup": vpc_cleanup})


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
            ("IAM 정리",      [("삭제 완료", _sum("iam_cleanup", "deleted")),
                               ("삭제 실패", _sum("iam_cleanup", "failed"))]),
            ("EC2 인스턴스",  [("종료 완료", _sum("ec2_cleanup", "terminated")),
                               ("종료 실패", _sum("ec2_cleanup", "failed"))]),
            ("EBS 볼륨",      [("삭제 완료", _sum("ebs_cleanup", "deleted")),
                               ("삭제 실패", _sum("ebs_cleanup", "failed"))]),
            ("AMI 정리",      [("해지 완료", _sum("ami_cleanup", "deregistered")),
                               ("해지 실패", _sum("ami_cleanup", "failed"))]),
            ("EBS 스냅샷",    [("삭제 완료", _sum("snap_cleanup", "deleted")),
                               ("삭제 실패", _sum("snap_cleanup", "failed"))]),
            ("RDS 스냅샷",    [("삭제 완료", _sum("rds_snap_cleanup", "deleted")),
                               ("삭제 실패", _sum("rds_snap_cleanup", "failed"))]),
            ("VPC 정리",      [("삭제 완료", _sum("vpc_cleanup", "deleted")),
                               ("삭제 실패", _sum("vpc_cleanup", "failed"))]),
            ("CloudFront",    [("삭제 완료",    _sum("cf_cleanup", "deleted")),
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
    clear_results()
    run_parallel(partial(_audit_account, delete_mode=delete_mode), creds)
    _print_audit_summary(len(creds), delete_mode=delete_mode)
    click.echo("\n모든 계정 검사 완료.")


# clean 커맨드 — audit --delete 의 별칭, 설명만 다르게 노출
@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
@click.option("--output", "-o", "output_fmt",
              type=click.Choice(["table", "json", "csv"]), default="table", show_default=True,
              help="출력 포맷")
@click.option("--yes", "-y", is_flag=True, help="삭제 확인 프롬프트 생략")
@click.option("--dry-run", is_flag=True, help="실제 변경 없이 결과 미리 보기")
def clean_cmd(credentials_file, account_filter, output_fmt, yes, dry_run):
    """잔여 리소스 스캔 후 삭제."""
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    delete_mode = not dry_run
    if delete_mode and not yes:
        click.confirm("잔여 리소스를 삭제하시겠습니까?", abort=True)

    click.echo(f"AWS 리소스 감사 + 삭제 시작 — 총 {len(creds)}개 계정\n")
    clear_results()
    run_parallel(partial(_audit_account, delete_mode=delete_mode), creds)
    _print_audit_summary(len(creds), delete_mode=delete_mode)
    click.echo("\n모든 계정 검사 완료.")
