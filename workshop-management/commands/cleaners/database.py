# =============================================================================
# commands/cleaners/database.py
# RDS 인스턴스/클러스터, ElastiCache, DynamoDB 테이블을 삭제한다.
# RDS/Aurora 삭제 시 final snapshot을 생성하지 않고 즉시 삭제한다.
# =============================================================================
from __future__ import annotations

import time

from botocore.exceptions import BotoCoreError, ClientError


def perform_dynamodb_cleanup(session, log: list, regions: list) -> dict:
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


def perform_elasticache_cleanup(session, log: list, regions: list) -> dict:
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


def perform_rds_cleanup(session, log: list, regions: list) -> dict:
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
