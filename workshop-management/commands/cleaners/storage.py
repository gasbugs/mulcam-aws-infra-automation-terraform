# =============================================================================
# commands/cleaners/storage.py
# S3, ECR, EFS, RDS 스냅샷, Backup 볼트, EC2 Key Pair를 삭제한다.
# =============================================================================
from __future__ import annotations

import time

from botocore.exceptions import BotoCoreError, ClientError


def perform_ecr_cleanup(session, log: list, regions: list) -> dict:
    """ECR 리포지토리를 이미지까지 포함해 삭제한다.
    force=True 옵션으로 내부 이미지가 있어도 한 번에 제거한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ecr = session.client("ecr", region_name=region)
            repos = ecr.describe_repositories().get("repositories", [])
            for repo in repos:
                name = repo["repositoryName"]
                try:
                    # force=True — 이미지가 남아 있어도 리포지토리째 삭제
                    ecr.delete_repository(repositoryName=name, force=True)
                    log.append(f"  [ECR 정리] 리포지토리 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [ECR 정리] 리포지토리 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_rds_snapshot_cleanup(session, log: list, regions: list) -> dict:
    """RDS DB 스냅샷과 Aurora 클러스터 스냅샷(수동 생성)을 삭제한다."""
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


def perform_s3_cleanup(session, log: list) -> dict:
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


def perform_keypair_cleanup(session, log: list, regions: list) -> dict:
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


def perform_efs_cleanup(session, log: list, regions: list) -> dict:
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


def perform_backup_cleanup(session, log: list, regions: list) -> dict:
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
