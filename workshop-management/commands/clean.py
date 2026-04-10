# =============================================================================
# commands/clean.py
# awsw clean — 스냅샷 기반 잔여 리소스 삭제
#
# audit 명령이 저장한 snapshots/audit_snapshot.json 을 읽어 발견된
# 리소스를 삭제하고, 결과를 snapshots/clean_history.json 에 기록한다.
# =============================================================================
from __future__ import annotations

import json
import os
import time
from datetime import datetime
from functools import partial
from pathlib import Path

import click
from botocore.exceptions import BotoCoreError, ClientError

from utils.credentials import filter_credentials, load_credentials
from utils.output import (
    account_sort_key, clear_results, flush_log, get_results,
    record_result, set_current_account,
)
from utils.parallel import run_parallel
from utils.constants import EXPECTED_IAM_USERS, PROTECTED_IAM_POLICIES
from utils.session import make_session


# ── 스냅샷 디렉토리 관리 ────────────────────────────────────────────────────────

def _get_snapshot_dir(credentials_file: str) -> Path:
    """자격증명 파일과 같은 디렉토리의 snapshots/ 폴더를 반환하고 없으면 생성한다."""
    base = Path(credentials_file).resolve().parent
    snap_dir = base / "snapshots"
    snap_dir.mkdir(exist_ok=True)
    return snap_dir


def _load_snapshot(credentials_file: str) -> dict | None:
    """최신 audit 스냅샷을 로드한다. 파일이 없으면 None 을 반환한다."""
    snap_path = _get_snapshot_dir(credentials_file) / "audit_snapshot.json"
    if not snap_path.exists():
        return None
    with snap_path.open(encoding="utf-8") as f:
        return json.load(f)


def _save_clean_history(
    credentials_file: str,
    snapshot_created_at: str,
    results: list[dict],
) -> Path:
    """삭제 결과를 clean_history.json 에 추가 기록하고 저장된 경로를 반환한다."""
    snap_dir  = _get_snapshot_dir(credentials_file)
    hist_path = snap_dir / "clean_history.json"

    # 기존 이력 로드 (없으면 빈 배열)
    history: list = []
    if hist_path.exists():
        try:
            with hist_path.open(encoding="utf-8") as f:
                history = json.load(f)
        except (json.JSONDecodeError, OSError):
            history = []

    # cleanup 결과만 추출 (실제로 삭제/실패가 있는 키만 포함)
    CLEANUP_KEYS = [
        "cf_cleanup", "iam_cleanup", "ami_cleanup", "snap_cleanup",
        "rds_snap_cleanup", "ec2_cleanup", "ebs_cleanup", "eip_cleanup",
        "lambda_cleanup", "apigateway_cleanup", "cloudwatch_cleanup",
        "vpc_cleanup", "imagebuilder_cleanup", "codecommit_cleanup",
        "s3_cleanup", "codepipeline_cleanup", "cw_alarm_cleanup",
        "ecs_cleanup", "eks_cleanup", "asg_cleanup", "elb_cleanup",
        "rds_cleanup", "elasticache_cleanup", "efs_cleanup",
        "secretsmanager_cleanup", "codebuild_cleanup", "wafv2_cleanup",
        "backup_cleanup", "dynamodb_cleanup", "sns_cleanup", "sqs_cleanup",
        "acm_cleanup", "route53_cleanup", "keypair_cleanup", "kms_cleanup",
    ]

    accounts_log = []
    for r in results:
        if r.get("status") == "error":
            continue
        cleanup_results = {
            k: r[k] for k in CLEANUP_KEYS
            if k in r and (
                r[k].get("deleted") or r[k].get("failed")
                or r[k].get("released") or r[k].get("terminated")
                or r[k].get("deregistered") or r[k].get("disabled")
            )
        }
        if cleanup_results:
            accounts_log.append({
                "name":            r["name"],
                "account_id":      r.get("account_id"),
                "cleanup_results": cleanup_results,
            })

    history.append({
        "cleaned_at":          datetime.now().isoformat(timespec="seconds"),
        "snapshot_created_at": snapshot_created_at,
        "accounts":            accounts_log,
    })

    with hist_path.open("w", encoding="utf-8") as f:
        json.dump(history, f, ensure_ascii=False, indent=2)

    return hist_path


def _delete_snapshot(credentials_file: str) -> None:
    """사용 완료된 스냅샷 파일을 삭제한다."""
    snap_path = _get_snapshot_dir(credentials_file) / "audit_snapshot.json"
    if snap_path.exists():
        snap_path.unlink()


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


# ── 신규 삭제 함수 (난이도 낮음) ───────────────────────────────────────────────

def _perform_codepipeline_cleanup(session, log: list, regions: list) -> dict:
    """CodePipeline 파이프라인을 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            cp = session.client("codepipeline", region_name=region)
            pipelines = cp.list_pipelines().get("pipelines", [])
            for p in pipelines:
                name = p["name"]
                try:
                    cp.delete_pipeline(name=name)
                    log.append(f"  [CodePipeline 정리] 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [CodePipeline 정리] 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_cloudwatch_alarm_cleanup(session, log: list, regions: list) -> dict:
    """CloudWatch 메트릭 알람을 모두 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            cw = session.client("cloudwatch", region_name=region)
            paginator = cw.get_paginator("describe_alarms")
            alarm_names = []
            for page in paginator.paginate():
                alarm_names.extend(a["AlarmName"] for a in page.get("MetricAlarms", []))
            if not alarm_names:
                continue
            # delete_alarms는 최대 100개씩 배치 삭제 가능
            for i in range(0, len(alarm_names), 100):
                batch = alarm_names[i:i+100]
                try:
                    cw.delete_alarms(AlarmNames=batch)
                    log.append(f"  [CloudWatch Alarm 정리] 알람 {len(batch)}개 삭제 완료 (리전: {region})")
                    result["deleted"].extend(batch)
                except ClientError as e:
                    log.append(f"  [CloudWatch Alarm 정리] 알람 삭제 실패 (리전: {region}): {e}")
                    result["failed"].extend(batch)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_acm_cleanup(session, log: list, regions: list) -> dict:
    """ACM 인증서를 삭제한다. 사용 중인 인증서는 건너뛴다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            acm = session.client("acm", region_name=region)
            certs = acm.list_certificates().get("CertificateSummaryList", [])
            for cert in certs:
                arn = cert["CertificateArn"]
                domain = cert.get("DomainName", arn)
                # InUseBy가 비어있어야 삭제 가능
                try:
                    detail = acm.describe_certificate(CertificateArn=arn).get("Certificate", {})
                    if detail.get("InUseBy"):
                        log.append(f"  [ACM 정리] 사용 중 — 스킵: {domain} (리전: {region})")
                        continue
                except ClientError:
                    pass
                try:
                    acm.delete_certificate(CertificateArn=arn)
                    log.append(f"  [ACM 정리] 삭제 완료: {domain} (리전: {region})")
                    result["deleted"].append(domain)
                except ClientError as e:
                    log.append(f"  [ACM 정리] 삭제 실패 ({domain}): {e}")
                    result["failed"].append(domain)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_keypair_cleanup(session, log: list, regions: list) -> dict:
    """EC2 키 페어를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            key_pairs = ec2.describe_key_pairs().get("KeyPairs", [])
            for kp in key_pairs:
                kp_id = kp.get("KeyPairId")
                kp_name = kp.get("KeyName", kp_id)
                try:
                    ec2.delete_key_pair(KeyPairId=kp_id)
                    log.append(f"  [Key Pair 정리] 삭제 완료: {kp_name} (리전: {region})")
                    result["deleted"].append(kp_name)
                except ClientError as e:
                    log.append(f"  [Key Pair 정리] 삭제 실패 ({kp_name}): {e}")
                    result["failed"].append(kp_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_sns_cleanup(session, log: list, regions: list) -> dict:
    """SNS 토픽을 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            sns = session.client("sns", region_name=region)
            topics = sns.list_topics().get("Topics", [])
            for t in topics:
                arn = t["TopicArn"]
                name = arn.rsplit(":", 1)[-1]
                try:
                    sns.delete_topic(TopicArn=arn)
                    log.append(f"  [SNS 정리] 토픽 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [SNS 정리] 토픽 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_sqs_cleanup(session, log: list, regions: list) -> dict:
    """SQS 큐를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            sqs = session.client("sqs", region_name=region)
            urls = sqs.list_queues().get("QueueUrls", [])
            for url in urls:
                name = url.rsplit("/", 1)[-1]
                try:
                    sqs.delete_queue(QueueUrl=url)
                    log.append(f"  [SQS 정리] 큐 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [SQS 정리] 큐 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_codebuild_cleanup(session, log: list, regions: list) -> dict:
    """CodeBuild 프로젝트를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            cb = session.client("codebuild", region_name=region)
            projects = cb.list_projects().get("projects", [])
            for name in projects:
                try:
                    cb.delete_project(name=name)
                    log.append(f"  [CodeBuild 정리] 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [CodeBuild 정리] 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_secretsmanager_cleanup(session, log: list, regions: list) -> dict:
    """Secrets Manager 시크릿을 즉시 삭제한다 (복구 기간 없이)."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            sm = session.client("secretsmanager", region_name=region)
            secrets = sm.list_secrets().get("SecretList", [])
            for secret in secrets:
                name = secret.get("Name", secret.get("ARN", "?"))
                try:
                    sm.delete_secret(SecretId=secret["ARN"], ForceDeleteWithoutRecovery=True)
                    log.append(f"  [Secrets Manager 정리] 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [Secrets Manager 정리] 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_asg_cleanup(session, log: list, regions: list) -> dict:
    """Auto Scaling Group을 강제 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            asg = session.client("autoscaling", region_name=region)
            groups = asg.describe_auto_scaling_groups().get("AutoScalingGroups", [])
            for g in groups:
                name = g["AutoScalingGroupName"]
                try:
                    asg.delete_auto_scaling_group(AutoScalingGroupName=name, ForceDelete=True)
                    log.append(f"  [ASG 정리] 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [ASG 정리] 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_kms_cleanup(session, log: list, regions: list) -> dict:
    """비활성화된 고객 관리형 KMS 키의 삭제를 예약한다 (7일 후 삭제)."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            kms = session.client("kms", region_name=region)
            keys = kms.list_keys().get("Keys", [])
            for key in keys:
                key_id = key["KeyId"]
                if not _kms_is_disabled_customer_key(kms, key_id):
                    continue
                try:
                    kms.schedule_key_deletion(KeyId=key_id, PendingWindowInDays=7)
                    log.append(f"  [KMS 정리] 삭제 예약 완료 (7일 후): {key_id} (리전: {region})")
                    result["deleted"].append(key_id)
                except ClientError as e:
                    log.append(f"  [KMS 정리] 삭제 예약 실패 ({key_id}): {e}")
                    result["failed"].append(key_id)
        except (ClientError, BotoCoreError):
            pass
    return result


# ── 신규 삭제 함수 (난이도 중간) ──────────────────────────────────────────────

def _perform_dynamodb_cleanup(session, log: list, regions: list) -> dict:
    """DynamoDB 테이블을 삭제한다. 삭제 보호가 켜져 있으면 먼저 해제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ddb = session.client("dynamodb", region_name=region)
            tables = ddb.list_tables().get("TableNames", [])
            for table_name in tables:
                try:
                    # 삭제 보호 해제 시도
                    try:
                        ddb.update_table(TableName=table_name, DeletionProtectionEnabled=False)
                    except ClientError:
                        pass
                    ddb.delete_table(TableName=table_name)
                    log.append(f"  [DynamoDB 정리] 테이블 삭제 완료: {table_name} (리전: {region})")
                    result["deleted"].append(table_name)
                except ClientError as e:
                    log.append(f"  [DynamoDB 정리] 테이블 삭제 실패 ({table_name}): {e}")
                    result["failed"].append(table_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_elasticache_cleanup(session, log: list, regions: list) -> dict:
    """ElastiCache 복제 그룹과 서브넷 그룹을 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ec = session.client("elasticache", region_name=region)
            # 복제 그룹 삭제 (스냅샷 생성 안 함)
            rgs = ec.describe_replication_groups().get("ReplicationGroups", [])
            for rg in rgs:
                rg_id = rg["ReplicationGroupId"]
                try:
                    ec.delete_replication_group(ReplicationGroupId=rg_id, RetainPrimaryCluster=False)
                    log.append(f"  [ElastiCache 정리] 복제 그룹 삭제 요청: {rg_id} (리전: {region})")
                    result["deleted"].append(rg_id)
                except ClientError as e:
                    log.append(f"  [ElastiCache 정리] 복제 그룹 삭제 실패 ({rg_id}): {e}")
                    result["failed"].append(rg_id)
            # 삭제 완료 대기 후 서브넷 그룹 정리
            if rgs:
                for _ in range(60):
                    time.sleep(10)
                    try:
                        remaining = ec.describe_replication_groups().get("ReplicationGroups", [])
                        if not remaining:
                            break
                    except ClientError:
                        break
            # 서브넷 그룹 삭제 (default 제외)
            try:
                sgs = ec.describe_cache_subnet_groups().get("CacheSubnetGroups", [])
                for sg in sgs:
                    sg_name = sg["CacheSubnetGroupName"]
                    if sg_name == "default":
                        continue
                    try:
                        ec.delete_cache_subnet_group(CacheSubnetGroupName=sg_name)
                        log.append(f"  [ElastiCache 정리] 서브넷 그룹 삭제: {sg_name} (리전: {region})")
                        result["deleted"].append(sg_name)
                    except ClientError:
                        pass
            except ClientError:
                pass
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_efs_cleanup(session, log: list, regions: list) -> dict:
    """EFS 파일 시스템을 삭제한다. 마운트 타깃을 먼저 제거해야 삭제 가능하다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            efs = session.client("efs", region_name=region)
            file_systems = efs.describe_file_systems().get("FileSystems", [])
            for fs in file_systems:
                fs_id = fs["FileSystemId"]
                fs_name = fs.get("Name") or fs_id
                try:
                    # 마운트 타깃 삭제
                    mts = efs.describe_mount_targets(FileSystemId=fs_id).get("MountTargets", [])
                    for mt in mts:
                        efs.delete_mount_target(MountTargetId=mt["MountTargetId"])
                    # 마운트 타깃 삭제 완료 대기
                    if mts:
                        for _ in range(30):
                            time.sleep(5)
                            remaining = efs.describe_mount_targets(FileSystemId=fs_id).get("MountTargets", [])
                            if not remaining:
                                break
                    efs.delete_file_system(FileSystemId=fs_id)
                    log.append(f"  [EFS 정리] 파일 시스템 삭제 완료: {fs_name} (리전: {region})")
                    result["deleted"].append(fs_name)
                except ClientError as e:
                    log.append(f"  [EFS 정리] 파일 시스템 삭제 실패 ({fs_name}): {e}")
                    result["failed"].append(fs_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_backup_cleanup(session, log: list, regions: list) -> dict:
    """Backup 볼트의 복구 지점을 삭제한 뒤 볼트를 제거한다. 기본 볼트는 건너뛴다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            backup = session.client("backup", region_name=region)
            vaults = backup.list_backup_vaults().get("BackupVaultList", [])
            for vault in vaults:
                vault_name = vault["BackupVaultName"]
                if vault_name in ("Default", "aws/efs/automatic-backup-vault"):
                    continue
                try:
                    # 복구 지점 삭제
                    rps = backup.list_recovery_points_by_backup_vault(
                        BackupVaultName=vault_name
                    ).get("RecoveryPoints", [])
                    for rp in rps:
                        try:
                            backup.delete_recovery_point(
                                BackupVaultName=vault_name,
                                RecoveryPointArn=rp["RecoveryPointArn"]
                            )
                        except ClientError:
                            pass
                    backup.delete_backup_vault(BackupVaultName=vault_name)
                    log.append(f"  [Backup 정리] 볼트 삭제 완료: {vault_name} (리전: {region})")
                    result["deleted"].append(vault_name)
                except ClientError as e:
                    log.append(f"  [Backup 정리] 볼트 삭제 실패 ({vault_name}): {e}")
                    result["failed"].append(vault_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_elb_cleanup(session, log: list, regions: list) -> dict:
    """ELB v1(Classic)과 v2(ALB/NLB) 로드 밸런서를 삭제한다.
    v2의 경우 리스너 → 타깃 그룹 → 로드 밸런서 순으로 삭제해야 한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        # Classic ELB (v1)
        try:
            elb = session.client("elb", region_name=region)
            lbs = elb.describe_load_balancers().get("LoadBalancerDescriptions", [])
            for lb in lbs:
                name = lb["LoadBalancerName"]
                try:
                    elb.delete_load_balancer(LoadBalancerName=name)
                    log.append(f"  [ELB 정리] Classic LB 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [ELB 정리] Classic LB 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
        # ALB/NLB (v2)
        try:
            elbv2 = session.client("elbv2", region_name=region)
            lbs = elbv2.describe_load_balancers().get("LoadBalancers", [])
            for lb in lbs:
                arn = lb["LoadBalancerArn"]
                name = lb.get("LoadBalancerName", arn)
                try:
                    # 리스너 삭제
                    listeners = elbv2.describe_listeners(LoadBalancerArn=arn).get("Listeners", [])
                    for listener in listeners:
                        try:
                            elbv2.delete_listener(ListenerArn=listener["ListenerArn"])
                        except ClientError:
                            pass
                    elbv2.delete_load_balancer(LoadBalancerArn=arn)
                    log.append(f"  [ELB 정리] ALB/NLB 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [ELB 정리] ALB/NLB 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
            # 타깃 그룹은 LB 삭제 후 별도 삭제 필요
            tgs = elbv2.describe_target_groups().get("TargetGroups", [])
            for tg in tgs:
                tg_arn = tg["TargetGroupArn"]
                tg_name = tg.get("TargetGroupName", tg_arn)
                try:
                    elbv2.delete_target_group(TargetGroupArn=tg_arn)
                    log.append(f"  [ELB 정리] 타깃 그룹 삭제 완료: {tg_name} (리전: {region})")
                    result["deleted"].append(tg_name)
                except ClientError:
                    pass  # 아직 사용 중일 수 있음 — 무시
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_wafv2_cleanup(session, log: list, regions: list) -> dict:
    """WAFv2 Web ACL을 삭제한다 (글로벌 + 리전)."""
    result: dict = {"deleted": [], "failed": []}
    # 글로벌 (CloudFront 연동)
    try:
        waf = session.client("wafv2", region_name="us-east-1")
        acls = waf.list_web_acls(Scope="CLOUDFRONT").get("WebACLs", [])
        for acl in acls:
            try:
                detail = waf.get_web_acl(Name=acl["Name"], Scope="CLOUDFRONT", Id=acl["Id"])
                lock_token = detail.get("LockToken")
                waf.delete_web_acl(Name=acl["Name"], Scope="CLOUDFRONT", Id=acl["Id"], LockToken=lock_token)
                log.append(f"  [WAFv2 정리] 글로벌 ACL 삭제 완료: {acl['Name']}")
                result["deleted"].append(acl["Name"])
            except ClientError as e:
                log.append(f"  [WAFv2 정리] 글로벌 ACL 삭제 실패 ({acl['Name']}): {e}")
                result["failed"].append(acl["Name"])
    except (ClientError, BotoCoreError):
        pass
    # 리전별
    for region in regions:
        try:
            waf = session.client("wafv2", region_name=region)
            acls = waf.list_web_acls(Scope="REGIONAL").get("WebACLs", [])
            for acl in acls:
                try:
                    detail = waf.get_web_acl(Name=acl["Name"], Scope="REGIONAL", Id=acl["Id"])
                    lock_token = detail.get("LockToken")
                    waf.delete_web_acl(Name=acl["Name"], Scope="REGIONAL", Id=acl["Id"], LockToken=lock_token)
                    log.append(f"  [WAFv2 정리] ACL 삭제 완료: {acl['Name']} (리전: {region})")
                    result["deleted"].append(acl["Name"])
                except ClientError as e:
                    log.append(f"  [WAFv2 정리] ACL 삭제 실패 ({acl['Name']}): {e}")
                    result["failed"].append(acl["Name"])
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_route53_cleanup(session, log: list) -> dict:
    """Route53 호스팅 영역의 레코드를 삭제한 뒤 영역을 제거한다."""
    result: dict = {"deleted": [], "failed": []}
    try:
        r53 = session.client("route53")
        zones = r53.list_hosted_zones().get("HostedZones", [])
        for zone in zones:
            zone_id = zone["Id"].split("/")[-1]
            zone_name = zone["Name"].rstrip(".")
            try:
                # NS/SOA 이외의 레코드를 모두 삭제
                paginator = r53.get_paginator("list_resource_record_sets")
                changes = []
                for page in paginator.paginate(HostedZoneId=zone_id):
                    for rr in page.get("ResourceRecordSets", []):
                        if rr["Type"] in ("NS", "SOA"):
                            continue
                        changes.append({"Action": "DELETE", "ResourceRecordSet": rr})
                # 변경 사항을 500개씩 배치 적용 (API 제한)
                for i in range(0, len(changes), 500):
                    batch = changes[i:i+500]
                    if batch:
                        r53.change_resource_record_sets(
                            HostedZoneId=zone_id,
                            ChangeBatch={"Changes": batch}
                        )
                r53.delete_hosted_zone(Id=zone_id)
                log.append(f"  [Route53 정리] 호스팅 영역 삭제 완료: {zone_name}")
                result["deleted"].append(zone_name)
            except ClientError as e:
                log.append(f"  [Route53 정리] 호스팅 영역 삭제 실패 ({zone_name}): {e}")
                result["failed"].append(zone_name)
    except (ClientError, BotoCoreError):
        pass
    return result


# ── 신규 삭제 함수 (난이도 높음) ──────────────────────────────────────────────

def _perform_ecs_full_cleanup(session, log: list, regions: list) -> dict:
    """ECS 서비스를 중지하고, 태스크 정의를 해제한 뒤, 클러스터를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ecs = session.client("ecs", region_name=region)
            cluster_arns = ecs.list_clusters().get("clusterArns", [])
            for cluster_arn in cluster_arns:
                cluster_name = cluster_arn.rsplit("/", 1)[-1]
                try:
                    # 1) 서비스 스케일다운 후 삭제
                    service_arns = ecs.list_services(cluster=cluster_arn).get("serviceArns", [])
                    for svc_arn in service_arns:
                        svc_name = svc_arn.rsplit("/", 1)[-1]
                        try:
                            ecs.update_service(cluster=cluster_arn, service=svc_arn, desiredCount=0)
                            ecs.delete_service(cluster=cluster_arn, service=svc_arn, force=True)
                            log.append(f"  [ECS 정리] 서비스 삭제: {svc_name} (리전: {region})")
                        except ClientError:
                            pass

                    # 2) 실행 중인 태스크 중지
                    task_arns = ecs.list_tasks(cluster=cluster_arn).get("taskArns", [])
                    for task_arn in task_arns:
                        try:
                            ecs.stop_task(cluster=cluster_arn, task=task_arn, reason="workshop cleanup")
                        except ClientError:
                            pass

                    # 3) 태스크 정의 해제 (이 클러스터에서 사용된 모든 활성 정의)
                    td_arns = ecs.list_task_definitions(status="ACTIVE").get("taskDefinitionArns", [])
                    for td_arn in td_arns:
                        try:
                            ecs.deregister_task_definition(taskDefinition=td_arn)
                        except ClientError:
                            pass

                    # 4) 컨테이너 인스턴스 해제 (EC2 시작 유형)
                    ci_arns = ecs.list_container_instances(cluster=cluster_arn).get("containerInstanceArns", [])
                    for ci_arn in ci_arns:
                        try:
                            ecs.deregister_container_instance(cluster=cluster_arn,
                                                              containerInstance=ci_arn, force=True)
                        except ClientError:
                            pass

                    # 5) 클러스터 삭제
                    ecs.delete_cluster(cluster=cluster_arn)
                    log.append(f"  [ECS 정리] 클러스터 삭제 완료: {cluster_name} (리전: {region})")
                    result["deleted"].append(cluster_name)
                except ClientError as e:
                    log.append(f"  [ECS 정리] 클러스터 삭제 실패 ({cluster_name}): {e}")
                    result["failed"].append(cluster_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_eks_full_cleanup(session, log: list, regions: list) -> dict:
    """EKS 노드 그룹, Fargate 프로파일, 애드온을 삭제한 뒤 클러스터를 제거한다.
    각 단계는 비동기이므로 삭제 완료까지 폴링한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            eks = session.client("eks", region_name=region)
            clusters = eks.list_clusters().get("clusters", [])
            for cluster_name in clusters:
                try:
                    # 1) Fargate 프로파일 삭제
                    fps = eks.list_fargate_profiles(clusterName=cluster_name).get("fargateProfileNames", [])
                    for fp_name in fps:
                        try:
                            eks.delete_fargate_profile(clusterName=cluster_name, fargateProfileName=fp_name)
                            log.append(f"  [EKS 정리] Fargate 프로파일 삭제 요청: {fp_name}")
                        except ClientError:
                            pass
                    # Fargate 삭제 완료 대기
                    for _ in range(60):
                        remaining = eks.list_fargate_profiles(clusterName=cluster_name).get("fargateProfileNames", [])
                        if not remaining:
                            break
                        time.sleep(10)

                    # 2) 노드 그룹 삭제
                    ngs = eks.list_nodegroups(clusterName=cluster_name).get("nodegroups", [])
                    for ng_name in ngs:
                        try:
                            eks.delete_nodegroup(clusterName=cluster_name, nodegroupName=ng_name)
                            log.append(f"  [EKS 정리] 노드 그룹 삭제 요청: {ng_name}")
                        except ClientError:
                            pass
                    # 노드 그룹 삭제 완료 대기
                    for _ in range(90):
                        remaining = eks.list_nodegroups(clusterName=cluster_name).get("nodegroups", [])
                        if not remaining:
                            break
                        time.sleep(10)

                    # 3) 애드온 삭제
                    addons = eks.list_addons(clusterName=cluster_name).get("addons", [])
                    for addon_name in addons:
                        try:
                            eks.delete_addon(clusterName=cluster_name, addonName=addon_name)
                        except ClientError:
                            pass

                    # 4) 클러스터 삭제
                    eks.delete_cluster(name=cluster_name)
                    log.append(f"  [EKS 정리] 클러스터 삭제 요청: {cluster_name} (리전: {region})")
                    # 클러스터 삭제 완료 대기
                    for _ in range(90):
                        try:
                            eks.describe_cluster(name=cluster_name)
                            time.sleep(10)
                        except ClientError:
                            break
                    log.append(f"  [EKS 정리] 클러스터 삭제 완료: {cluster_name} (리전: {region})")
                    result["deleted"].append(cluster_name)
                except ClientError as e:
                    log.append(f"  [EKS 정리] 클러스터 삭제 실패 ({cluster_name}): {e}")
                    result["failed"].append(cluster_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def _perform_rds_cleanup(session, log: list, regions: list) -> dict:
    """RDS 인스턴스와 Aurora 클러스터를 삭제한다.
    삭제 보호 해제 → 인스턴스 삭제 → 클러스터 삭제 → 서브넷 그룹 삭제 순서로 진행한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            rds = session.client("rds", region_name=region)

            # 1) RDS 인스턴스 삭제 (Aurora 멤버 포함)
            instances = rds.describe_db_instances().get("DBInstances", [])
            for inst in instances:
                db_id = inst["DBInstanceIdentifier"]
                try:
                    # 삭제 보호 해제
                    if inst.get("DeletionProtection"):
                        rds.modify_db_instance(DBInstanceIdentifier=db_id, DeletionProtection=False)
                        # 설정 적용 대기
                        time.sleep(5)
                    rds.delete_db_instance(
                        DBInstanceIdentifier=db_id,
                        SkipFinalSnapshot=True,
                        DeleteAutomatedBackups=True,
                    )
                    log.append(f"  [RDS 정리] 인스턴스 삭제 요청: {db_id} (리전: {region})")
                    result["deleted"].append(db_id)
                except ClientError as e:
                    log.append(f"  [RDS 정리] 인스턴스 삭제 실패 ({db_id}): {e}")
                    result["failed"].append(db_id)

            # 인스턴스 삭제 완료 대기
            if instances:
                for _ in range(60):
                    time.sleep(10)
                    try:
                        remaining = rds.describe_db_instances().get("DBInstances", [])
                        if not remaining:
                            break
                    except ClientError:
                        break

            # 2) Aurora 클러스터 삭제
            clusters = rds.describe_db_clusters().get("DBClusters", [])
            for cluster in clusters:
                cluster_id = cluster["DBClusterIdentifier"]
                try:
                    if cluster.get("DeletionProtection"):
                        rds.modify_db_cluster(DBClusterIdentifier=cluster_id, DeletionProtection=False)
                        time.sleep(5)
                    rds.delete_db_cluster(DBClusterIdentifier=cluster_id, SkipFinalSnapshot=True)
                    log.append(f"  [RDS 정리] 클러스터 삭제 요청: {cluster_id} (리전: {region})")
                    result["deleted"].append(cluster_id)
                except ClientError as e:
                    log.append(f"  [RDS 정리] 클러스터 삭제 실패 ({cluster_id}): {e}")
                    result["failed"].append(cluster_id)

            # 3) DB 서브넷 그룹 삭제 (default 제외)
            try:
                subnet_groups = rds.describe_db_subnet_groups().get("DBSubnetGroups", [])
                for sg in subnet_groups:
                    sg_name = sg["DBSubnetGroupName"]
                    if sg_name == "default":
                        continue
                    try:
                        rds.delete_db_subnet_group(DBSubnetGroupName=sg_name)
                        log.append(f"  [RDS 정리] 서브넷 그룹 삭제: {sg_name} (리전: {region})")
                        result["deleted"].append(sg_name)
                    except ClientError:
                        pass
            except ClientError:
                pass

        except (ClientError, BotoCoreError):
            pass
    return result


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
                           "imagebuilder_cleanup": {}, "codecommit_cleanup": {}, "s3_cleanup": {},
                           "codepipeline_cleanup": {}, "cw_alarm_cleanup": {},
                           "ecs_cleanup": {}, "eks_cleanup": {}, "asg_cleanup": {},
                           "elb_cleanup": {}, "rds_cleanup": {}, "elasticache_cleanup": {},
                           "efs_cleanup": {}, "secretsmanager_cleanup": {},
                           "codebuild_cleanup": {}, "wafv2_cleanup": {},
                           "backup_cleanup": {}, "dynamodb_cleanup": {},
                           "sns_cleanup": {}, "sqs_cleanup": {},
                           "acm_cleanup": {}, "route53_cleanup": {},
                           "keypair_cleanup": {}, "kms_cleanup": {}})
            return

    # 감사에서 발견된 리소스 타입만 삭제 — 없는 타입은 API 호출조차 하지 않는다
    warnings = cred.get("_audit_warnings", [])
    def _found(keyword: str) -> bool:
        return any(keyword in w for w in warnings)

    should_run = {
        "codepipeline_cleanup":    _found("CodePipeline"),
        "lambda_cleanup":          _found("Lambda"),
        "apigateway_cleanup":      _found("API Gateway"),
        "cw_alarm_cleanup":        _found("CloudWatch Alarms"),
        "cloudwatch_cleanup":      _found("CloudWatch"),
        "ecs_cleanup":             _found("ECS"),
        "eks_cleanup":             _found("EKS"),
        "asg_cleanup":             _found("AutoScalingGroups"),
        "elb_cleanup":             _found("ELB"),
        "rds_cleanup":             _found("RDS") and not _found("RDS Snapshots"),
        "elasticache_cleanup":     _found("ElastiCache"),
        "efs_cleanup":             _found("EFS"),
        "secretsmanager_cleanup":  _found("SecretManager"),
        "codebuild_cleanup":       _found("CodeBuild"),
        "wafv2_cleanup":           _found("WAFv2"),
        "backup_cleanup":          _found("Backup"),
        "dynamodb_cleanup":        _found("DynamoDB"),
        "sns_cleanup":             _found("SNS"),
        "sqs_cleanup":             _found("SQS"),
        "iam_cleanup":             _found("IAM"),
        "cf_cleanup":              _found("CloudFront"),
        "acm_cleanup":             _found("ACM"),
        "ami_cleanup":             _found("AMI"),
        "snap_cleanup":            _found("EBS Snapshots"),
        "rds_snap_cleanup":        _found("RDS Snapshots") or _found("RDS Cluster"),
        "imagebuilder_cleanup":    _found("Image Builder"),
        "codecommit_cleanup":      _found("CodeCommit"),
        "s3_cleanup":              _found("S3 Buckets"),
        "route53_cleanup":         _found("Route53"),
        "ec2_cleanup":             _found("EC2 Instances"),
        "keypair_cleanup":         _found("Key Pairs"),
        "eip_cleanup":             _found("EIP"),
        "ebs_cleanup":             _found("EBS Volumes"),
        "vpc_cleanup":             _found("VPC"),
        "kms_cleanup":             _found("KMS"),
    }

    # 실행할 작업만 필터링 (순서 유지: 의존 관계 반영)
    ALL_OPS = [
        ("codepipeline_cleanup",    lambda: _perform_codepipeline_cleanup(session, log, regions),     "CodePipeline 삭제 중"),
        ("lambda_cleanup",          lambda: _perform_lambda_cleanup(session, log, regions),           "Lambda 삭제 중"),
        ("apigateway_cleanup",      lambda: _perform_apigateway_cleanup(session, log, regions),      "API Gateway 삭제 중"),
        ("cw_alarm_cleanup",        lambda: _perform_cloudwatch_alarm_cleanup(session, log, regions), "CloudWatch 알람 삭제 중"),
        ("cloudwatch_cleanup",      lambda: _perform_cloudwatch_cleanup(session, log, regions),      "CloudWatch 로그 그룹 삭제 중"),
        ("ecs_cleanup",             lambda: _perform_ecs_full_cleanup(session, log, regions),         "ECS 정리 중"),
        ("eks_cleanup",             lambda: _perform_eks_full_cleanup(session, log, regions),         "EKS 정리 중"),
        ("asg_cleanup",             lambda: _perform_asg_cleanup(session, log, regions),              "ASG 삭제 중"),
        ("elb_cleanup",             lambda: _perform_elb_cleanup(session, log, regions),              "ELB 삭제 중"),
        ("rds_cleanup",             lambda: _perform_rds_cleanup(session, log, regions),              "RDS 인스턴스/클러스터 삭제 중"),
        ("elasticache_cleanup",     lambda: _perform_elasticache_cleanup(session, log, regions),      "ElastiCache 삭제 중"),
        ("efs_cleanup",             lambda: _perform_efs_cleanup(session, log, regions),              "EFS 삭제 중"),
        ("secretsmanager_cleanup",  lambda: _perform_secretsmanager_cleanup(session, log, regions),   "Secrets Manager 삭제 중"),
        ("codebuild_cleanup",       lambda: _perform_codebuild_cleanup(session, log, regions),        "CodeBuild 삭제 중"),
        ("wafv2_cleanup",           lambda: _perform_wafv2_cleanup(session, log, regions),            "WAFv2 삭제 중"),
        ("backup_cleanup",          lambda: _perform_backup_cleanup(session, log, regions),           "Backup 볼트 삭제 중"),
        ("dynamodb_cleanup",        lambda: _perform_dynamodb_cleanup(session, log, regions),         "DynamoDB 삭제 중"),
        ("sns_cleanup",             lambda: _perform_sns_cleanup(session, log, regions),              "SNS 삭제 중"),
        ("sqs_cleanup",             lambda: _perform_sqs_cleanup(session, log, regions),              "SQS 삭제 중"),
        ("iam_cleanup",             lambda: _perform_iam_cleanup(session, log),                       "IAM 정리 중"),
        ("cf_cleanup",              lambda: _perform_cloudfront_cleanup(session, log),                "CloudFront 정리 중"),
        ("acm_cleanup",             lambda: _perform_acm_cleanup(session, log, regions),              "ACM 인증서 삭제 중"),
        ("ami_cleanup",             lambda: _perform_ami_cleanup(session, log, regions),              "AMI 정리 중"),
        ("snap_cleanup",            lambda: _perform_ebs_snapshot_cleanup(session, log, regions),     "EBS 스냅샷 삭제 중"),
        ("rds_snap_cleanup",        lambda: _perform_rds_snapshot_cleanup(session, log, regions),     "RDS 스냅샷 삭제 중"),
        # Image Builder 의존 순서: 파이프라인 → 레시피 → 컴포넌트 → 인프라/배포 설정
        ("imagebuilder_cleanup",    lambda: _perform_imagebuilder_cleanup(session, log, regions),     "Image Builder 정리 중"),
        ("codecommit_cleanup",      lambda: _perform_codecommit_cleanup(session, log, regions),      "CodeCommit 정리 중"),
        ("s3_cleanup",              lambda: _perform_s3_cleanup(session, log),                        "S3 버킷 삭제 중"),
        ("route53_cleanup",         lambda: _perform_route53_cleanup(session, log),                   "Route53 정리 중"),
        ("ec2_cleanup",             lambda: _perform_ec2_cleanup(session, log, regions),              "EC2 종료 중"),
        ("keypair_cleanup",         lambda: _perform_keypair_cleanup(session, log, regions),          "Key Pair 삭제 중"),
        ("eip_cleanup",             lambda: _perform_eip_cleanup(session, log, regions),              "EIP 해제 중"),
        ("ebs_cleanup",             lambda: _perform_ebs_volume_cleanup(session, log, regions),       "EBS 볼륨 삭제 중"),
        ("vpc_cleanup",             lambda: _perform_vpc_cleanup(session, log, regions),              "VPC 삭제 중"),
        ("kms_cleanup",             lambda: _perform_kms_cleanup(session, log, regions),              "KMS 삭제 예약 중"),
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

def _print_delete_summary() -> None:
    """삭제 단계 결과 요약을 출력한다."""
    results = get_results()
    def _sum(key, sub): return sum(len(r.get(key, {}).get(sub, [])) for r in results)

    stats = [
        ("CodePipeline 정리", [("삭제 완료", _sum("codepipeline_cleanup", "deleted")),
                               ("삭제 실패", _sum("codepipeline_cleanup", "failed"))]),
        ("Lambda 정리",       [("삭제 완료", _sum("lambda_cleanup",       "deleted")),
                               ("삭제 실패", _sum("lambda_cleanup",       "failed"))]),
        ("API Gateway 정리",  [("삭제 완료", _sum("apigateway_cleanup",   "deleted")),
                               ("삭제 실패", _sum("apigateway_cleanup",   "failed"))]),
        ("CW 알람 정리",      [("삭제 완료", _sum("cw_alarm_cleanup",     "deleted")),
                               ("삭제 실패", _sum("cw_alarm_cleanup",     "failed"))]),
        ("CloudWatch 정리",   [("삭제 완료", _sum("cloudwatch_cleanup",   "deleted")),
                               ("삭제 실패", _sum("cloudwatch_cleanup",   "failed"))]),
        ("ECS 정리",          [("삭제 완료", _sum("ecs_cleanup",          "deleted")),
                               ("삭제 실패", _sum("ecs_cleanup",          "failed"))]),
        ("EKS 정리",          [("삭제 완료", _sum("eks_cleanup",          "deleted")),
                               ("삭제 실패", _sum("eks_cleanup",          "failed"))]),
        ("ASG 정리",          [("삭제 완료", _sum("asg_cleanup",          "deleted")),
                               ("삭제 실패", _sum("asg_cleanup",          "failed"))]),
        ("ELB 정리",          [("삭제 완료", _sum("elb_cleanup",          "deleted")),
                               ("삭제 실패", _sum("elb_cleanup",          "failed"))]),
        ("RDS 정리",          [("삭제 완료", _sum("rds_cleanup",          "deleted")),
                               ("삭제 실패", _sum("rds_cleanup",          "failed"))]),
        ("ElastiCache 정리",  [("삭제 완료", _sum("elasticache_cleanup",  "deleted")),
                               ("삭제 실패", _sum("elasticache_cleanup",  "failed"))]),
        ("EFS 정리",          [("삭제 완료", _sum("efs_cleanup",          "deleted")),
                               ("삭제 실패", _sum("efs_cleanup",          "failed"))]),
        ("Secrets Manager",   [("삭제 완료", _sum("secretsmanager_cleanup", "deleted")),
                               ("삭제 실패", _sum("secretsmanager_cleanup", "failed"))]),
        ("CodeBuild 정리",    [("삭제 완료", _sum("codebuild_cleanup",    "deleted")),
                               ("삭제 실패", _sum("codebuild_cleanup",    "failed"))]),
        ("WAFv2 정리",        [("삭제 완료", _sum("wafv2_cleanup",        "deleted")),
                               ("삭제 실패", _sum("wafv2_cleanup",        "failed"))]),
        ("Backup 정리",       [("삭제 완료", _sum("backup_cleanup",       "deleted")),
                               ("삭제 실패", _sum("backup_cleanup",       "failed"))]),
        ("DynamoDB 정리",     [("삭제 완료", _sum("dynamodb_cleanup",     "deleted")),
                               ("삭제 실패", _sum("dynamodb_cleanup",     "failed"))]),
        ("SNS 정리",          [("삭제 완료", _sum("sns_cleanup",          "deleted")),
                               ("삭제 실패", _sum("sns_cleanup",          "failed"))]),
        ("SQS 정리",          [("삭제 완료", _sum("sqs_cleanup",          "deleted")),
                               ("삭제 실패", _sum("sqs_cleanup",          "failed"))]),
        ("IAM 정리",          [("삭제 완료", _sum("iam_cleanup",          "deleted")),
                               ("삭제 실패", _sum("iam_cleanup",          "failed"))]),
        ("ACM 정리",          [("삭제 완료", _sum("acm_cleanup",          "deleted")),
                               ("삭제 실패", _sum("acm_cleanup",          "failed"))]),
        ("Image Builder 정리",[("삭제 완료", _sum("imagebuilder_cleanup", "deleted")),
                               ("삭제 실패", _sum("imagebuilder_cleanup", "failed"))]),
        ("CodeCommit 정리",   [("삭제 완료", _sum("codecommit_cleanup",   "deleted")),
                               ("삭제 실패", _sum("codecommit_cleanup",   "failed"))]),
        ("S3 버킷 정리",      [("삭제 완료", _sum("s3_cleanup",           "deleted")),
                               ("삭제 실패", _sum("s3_cleanup",           "failed"))]),
        ("Route53 정리",      [("삭제 완료", _sum("route53_cleanup",      "deleted")),
                               ("삭제 실패", _sum("route53_cleanup",      "failed"))]),
        ("EC2 인스턴스",      [("종료 완료", _sum("ec2_cleanup",          "terminated")),
                               ("종료 실패", _sum("ec2_cleanup",          "failed"))]),
        ("Key Pair 정리",     [("삭제 완료", _sum("keypair_cleanup",      "deleted")),
                               ("삭제 실패", _sum("keypair_cleanup",      "failed"))]),
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
        ("KMS 정리",          [("삭제 예약", _sum("kms_cleanup",          "deleted")),
                               ("예약 실패", _sum("kms_cleanup",          "failed"))]),
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
@click.option("--yes", "-y", is_flag=True, help="삭제 확인 프롬프트 생략")
def cmd(credentials_file, account_filter, yes):
    """스냅샷 기반 잔여 리소스 삭제. audit 명령으로 먼저 스냅샷을 생성해야 한다."""
    # ── 스냅샷 로드 ──────────────────────────────────────────────────────────
    snapshot = _load_snapshot(credentials_file)
    if snapshot is None:
        click.echo(
            "스냅샷 파일(snapshots/audit_snapshot.json)이 없습니다.\n"
            "먼저 awsw audit 을 실행하여 스냅샷을 생성하세요."
        )
        return

    snapshot_created_at = snapshot.get("created_at", "unknown")
    click.echo(
        f"\n[스냅샷 정보] 생성 시각: {snapshot_created_at} "
        f"/ 계정 수: {snapshot['total_accounts']}개\n"
    )

    # 잔여 리소스가 있는 계정만 추출
    dirty_accounts = [
        a for a in snapshot["accounts"] if a["status"] == "has_resources"
    ]
    if not dirty_accounts:
        click.echo("스냅샷에 잔여 리소스가 없습니다. 정리할 항목이 없습니다.")
        _delete_snapshot(credentials_file)
        return

    # 발견된 리소스 목록 출력
    click.echo(f"잔여 리소스 발견 계정: {len(dirty_accounts)}개")
    for a in sorted(dirty_accounts, key=account_sort_key):
        click.echo(f"  {a['name']:<10}  계정 ID: {a.get('account_id', 'N/A')}  ({len(a['warnings'])}건)")
        for w in sorted(a["warnings"]):
            click.echo(f"    └ {w}")

    # ── 삭제 확인 ────────────────────────────────────────────────────────────
    if not yes:
        try:
            click.confirm(
                f"\n위 리소스를 삭제하시겠습니까? ({len(dirty_accounts)}개 계정)",
                abort=True,
            )
        except click.exceptions.Abort:
            click.echo("\n취소됐습니다.")
            return

    # ── 자격증명 로드 및 스냅샷 계정과 매핑 ──────────────────────────────────
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    # 스냅샷 계정명 → warnings 맵
    warnings_map = {a["name"]: a["warnings"] for a in dirty_accounts}

    # 자격증명 중 스냅샷에서 잔여 리소스가 발견된 계정만 선택
    dirty_creds = [c for c in creds if c["name"] in warnings_map]
    if not dirty_creds:
        click.echo("스냅샷 계정명과 자격증명 파일의 계정명이 일치하지 않습니다.")
        return

    # ── 리전 목록 조회 ────────────────────────────────────────────────────────
    try:
        first_session = make_session(dirty_creds[0]["access_key"], dirty_creds[0]["secret_key"])
        regions = [
            r["RegionName"] for r in first_session.client(
                "ec2", region_name="us-east-1"
            ).describe_regions(
                Filters=[{"Name": "opt-in-status", "Values": ["opted-in", "opt-in-not-required"]}]
            )["Regions"]
        ]
    except ClientError as e:
        click.echo(f"리전 목록 조회 실패: {e}")
        return

    # _audit_warnings: 감사에서 발견된 경고 목록 주입 (선택적 삭제 최적화)
    # _regions: 1회 조회한 리전 목록 재사용
    enriched = [
        {**c, "_audit_warnings": warnings_map[c["name"]], "_regions": regions}
        for c in dirty_creds
    ]

    # ── 삭제 실행 ────────────────────────────────────────────────────────────
    click.echo(f"\n[리소스 삭제] {len(enriched)}개 계정\n")
    clear_results()
    run_parallel(_delete_account, enriched)
    _print_delete_summary()

    # ── 이력 저장 + 스냅샷 정리 ──────────────────────────────────────────────
    hist_path = _save_clean_history(credentials_file, snapshot_created_at, get_results())
    click.echo(f"\n삭제 이력 저장: {hist_path}")
    _delete_snapshot(credentials_file)
    click.echo("스냅샷 파일 삭제 완료.")
    click.echo("\n모든 계정 정리 완료.")
