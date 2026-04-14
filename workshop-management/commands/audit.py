# =============================================================================
# commands/audit.py
# awsw audit — 잔여 리소스 스캔 + 스냅샷 저장
#
# 기존 aws-resource-audit.py 의 로직을 click 커맨드로 래핑한다.
# 삭제 기능은 commands/clean.py 를 참고하세요.
# =============================================================================
from __future__ import annotations

import concurrent.futures
import json
from datetime import datetime
from pathlib import Path

import click
from botocore.exceptions import BotoCoreError, ClientError

from commands.cleaners.misc import kms_is_disabled_customer_key
from utils.constants import EXPECTED_IAM_USERS, PROTECTED_IAM_POLICIES
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
    "KMS Keys (CMK)":         ("kms",             "regional", "list_keys",                     "Keys"),
    "ELB (v1)":               ("elb",             "regional", "describe_load_balancers",       "LoadBalancerDescriptions"),
    "ELB (v2)":               ("elbv2",           "regional", "describe_load_balancers",       "LoadBalancers"),
    "EKS Clusters":           ("eks",             "regional", "list_clusters",                 "clusters"),
    "Lambda":                 ("lambda",           "regional", "list_functions",               "Functions"),
    "SecretManager":          ("secretsmanager",  "regional", "list_secrets",                  "SecretList"),
    "RDS":                    ("rds",             "regional", "describe_db_instances",         "DBInstances"),
    "RDS Snapshots":          ("rds",             "regional", "describe_db_snapshots",         "DBSnapshots"),
    "RDS Cluster Snapshots":  ("rds",             "regional", "describe_db_cluster_snapshots", "DBClusterSnapshots"),
    "ECS Clusters":           ("ecs",             "regional", "list_clusters",                 "clusterArns"),
    # 클러스터 없이 남아 있는 고아 태스크 정의도 별도로 탐지 — 요금은 없지만 감사 목적으로 포함
    "ECS Task Definitions":   ("ecs",             "regional", "list_task_definitions",          "taskDefinitionArns"),
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
    # ── 추가 리소스 (Terraform 프로젝트에서 사용하지만 기존에 누락된 항목) ──
    "DynamoDB Tables":             ("dynamodb",     "regional", "list_tables",                                 "TableNames"),
    "ElastiCache":                 ("elasticache",  "regional", "describe_replication_groups",                  "ReplicationGroups"),
    "EFS File Systems":            ("efs",          "regional", "describe_file_systems",                        "FileSystems"),
    "CodePipeline":                ("codepipeline", "regional", "list_pipelines",                               "pipelines"),
    "CloudWatch Alarms":           ("cloudwatch",   "regional", "describe_alarms",                              "MetricAlarms"),
    "ACM Certificates":            ("acm",          "regional", "list_certificates",                            "CertificateSummaryList"),
    "Key Pairs":                   ("ec2",          "regional", "describe_key_pairs",                           "KeyPairs"),
    "SNS Topics":                  ("sns",          "regional", "list_topics",                                  "Topics"),
    "SQS Queues":                  ("sqs",          "regional", "list_queues",                                  "QueueUrls"),
    "Backup Vaults":               ("backup",       "regional", "list_backup_vaults",                           "BackupVaultList"),
    # NAT Gateway — 시간당 약 $0.045 과금, 잔여 시 비용 발생 주의
    "NAT Gateways":                ("ec2",          "regional", "describe_nat_gateways",                        "NatGateways"),
    # Security Groups — default SG를 제외한 사용자 생성 SG 탐지
    "Security Groups":             ("ec2",          "regional", "describe_security_groups",                     "SecurityGroups"),
}


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
                # 배포별 모니터링 구독(실시간 메트릭 플랜) 활성화 여부 추가 확인
                subscribed = 0
                for d in all_dists:
                    try:
                        resp = client.get_monitoring_subscription(DistributionId=d["Id"])
                        s = (resp.get("MonitoringSubscription", {})
                             .get("RealtimeMetricsSubscriptionConfig", {})
                             .get("RealtimeMetricsSubscriptionStatus", "Disabled"))
                        if s == "Enabled":
                            subscribed += 1
                    except Exception:
                        pass
                if subscribed:
                    parts.append(f"모니터링 구독 활성화 {subscribed}개 → clean 시 자동 해지")
                return f"CloudFront 리소스 {len(all_dists)}개 발견 (글로벌) — {', '.join(parts)}"

        elif resource_name == "KMS Keys (CMK)":
            keys = client.list_keys().get(result_key, [])
            # Enabled·Disabled 상태의 고객 관리형 키를 탐지 (PendingDeletion은 이미 처리 중이므로 제외)
            target_keys = [k for k in keys if kms_is_disabled_customer_key(client, k["KeyId"])]
            if target_keys:
                return f"{resource_name} 리소스 {len(target_keys)}개 발견 (리전: {region})"

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
            # 서비스 연결 역할(service-linked role), AWS SSO 예약 역할, AWS 관리형 역할 제외
            # AWSReservedSSO_* 역할은 IAM Identity Center(SSO)가 자동 생성하는 시스템 역할로
            # 삭제하면 SSO 로그인이 불가해지므로 반드시 제외한다
            roles = [r for r in client.list_roles().get(result_key, [])
                     if not r.get("Path", "").startswith("/aws-service-role/")
                     and not r.get("Path", "").startswith("/aws-reserved/")
                     and "AWSServiceRole" not in r.get("RoleName", "")
                     and "AWSReservedSSO" not in r.get("RoleName", "")]
            if roles:
                return f"IAM 역할 {len(roles)}개 발견: {', '.join(r['RoleName'] for r in roles)}"

        elif resource_name == "IAM Policies (Custom)":
            # Scope=Local → 고객 관리형 정책만 조회 (AWS 관리형 및 보호 정책 제외)
            policies = [p for p in client.list_policies(Scope="Local").get(result_key, [])
                        if p["PolicyName"] not in PROTECTED_IAM_POLICIES]
            if policies:
                return f"IAM 정책 {len(policies)}개 발견: {', '.join(p['PolicyName'] for p in policies)}"

        # ── 신규 리소스 검사 ──
        elif resource_name == "DynamoDB Tables":
            # list_tables 결과는 문자열 리스트(테이블명)이므로 별도 처리
            tables = client.list_tables().get(result_key, [])
            if tables:
                return (f"[비용주의] {resource_name} {len(tables)}개 발견 (리전: {region})"
                        f" → {', '.join(tables)}")

        elif resource_name == "ElastiCache":
            resources = client.describe_replication_groups().get(result_key, [])
            if resources:
                names = [r.get("ReplicationGroupId", "?") for r in resources]
                return (f"[비용주의] {resource_name} 리소스 {len(resources)}개 발견 (리전: {region})"
                        f" → {', '.join(names)}")

        elif resource_name == "EFS File Systems":
            resources = client.describe_file_systems().get(result_key, [])
            if resources:
                names = [fs.get("Name") or fs["FileSystemId"] for fs in resources]
                return (f"[비용주의] {resource_name} {len(resources)}개 발견 (리전: {region})"
                        f" → {', '.join(names)}")

        elif resource_name == "Backup Vaults":
            # 기본 볼트('Default', 'aws/efs/automatic-backup-vault')는 삭제 대상에서 제외
            vaults = [v for v in client.list_backup_vaults().get(result_key, [])
                      if v["BackupVaultName"] not in ("Default", "aws/efs/automatic-backup-vault")]
            if vaults:
                return (f"{resource_name} {len(vaults)}개 발견 (리전: {region})"
                        f" → {', '.join(v['BackupVaultName'] for v in vaults)}")

        elif resource_name == "SQS Queues":
            # list_queues 결과는 URL 문자열 리스트이므로 별도 처리
            urls = client.list_queues().get(result_key, [])
            if urls:
                names = [u.rsplit("/", 1)[-1] for u in urls]
                return f"{resource_name} {len(urls)}개 발견 (리전: {region}) → {', '.join(names)}"

        elif resource_name == "SNS Topics":
            # list_topics 결과는 {"TopicArn": "..."} 리스트
            topics = client.list_topics().get(result_key, [])
            if topics:
                names = [t["TopicArn"].rsplit(":", 1)[-1] for t in topics]
                return f"{resource_name} {len(topics)}개 발견 (리전: {region}) → {', '.join(names)}"

        elif resource_name == "NAT Gateways":
            # available·pending 상태만 집계 — deleted·deleting은 이미 정리 중이므로 제외
            nat_gws = client.describe_nat_gateways(
                Filters=[{"Name": "state", "Values": ["available", "pending"]}]
            ).get(result_key, [])
            if nat_gws:
                ids = [n["NatGatewayId"] for n in nat_gws]
                return (f"[비용주의] {resource_name} {len(nat_gws)}개 발견 (리전: {region})"
                        f" → {', '.join(ids)}")

        elif resource_name == "Security Groups":
            # "default" 이름의 SG는 VPC 기본 제공 항목이므로 탐지 제외
            sgs = [sg for sg in client.describe_security_groups().get(result_key, [])
                   if sg.get("GroupName") != "default"]
            if sgs:
                names = [sg.get("GroupName", sg["GroupId"]) for sg in sgs]
                return (f"{resource_name} {len(sgs)}개 발견 (리전: {region})"
                        f" → {', '.join(names)}")

        elif resource_name == "ECS Task Definitions":
            # ACTIVE 상태의 태스크 정의만 탐지 — 이미 deregister된 INACTIVE는 제외
            td_arns = client.list_task_definitions(status="ACTIVE").get(result_key, [])
            if td_arns:
                # ARN에서 패밀리명만 추출 (예: arn:.../netflux:3 → netflux)
                families = sorted({arn.split("/")[1].rsplit(":", 1)[0] for arn in td_arns})
                return (f"ECS Task Definitions {len(td_arns)}개 발견 (리전: {region})"
                        f" → {', '.join(families)}")

        else:
            resources = getattr(client, api_call)().get(result_key, [])
            if resources:
                return f"{resource_name} 리소스 {len(resources)}개 발견 (리전: {region})"

    except (ClientError, BotoCoreError):
        pass
    return None


# ── 스냅샷 저장/회전 ───────────────────────────────────────────────────────────
_MAX_HISTORY = 3  # 보관할 이력 파일 최대 개수


def _get_snapshot_dir(credentials_file: str) -> Path:
    """자격증명 파일과 같은 디렉토리의 snapshots/ 폴더를 반환한다."""
    base = Path(credentials_file).resolve().parent
    snap_dir = base / "snapshots"
    snap_dir.mkdir(exist_ok=True)
    return snap_dir


def _rotate_snapshot(credentials_file: str) -> None:
    """기존 스냅샷을 타임스탬프 이력 파일로 이름 변경하고 오래된 이력을 삭제한다.
    이력 파일은 최대 _MAX_HISTORY 개만 보관한다."""
    snap_dir  = _get_snapshot_dir(credentials_file)
    snap_path = snap_dir / "audit_snapshot.json"
    if not snap_path.exists():
        return

    # 타임스탬프를 포함한 이력 파일명으로 이동
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    snap_path.rename(snap_dir / f"audit_snapshot_{ts}.json")

    # 오래된 이력 정리 (mtime 기준 오름차순 정렬 → 가장 오래된 것부터 삭제)
    history_files = sorted(
        snap_dir.glob("audit_snapshot_*.json"),
        key=lambda p: p.stat().st_mtime,
    )
    for old_file in history_files[:-_MAX_HISTORY]:
        old_file.unlink()


def _save_snapshot(credentials_file: str, results: list[dict]) -> Path:
    """감사 결과를 JSON 스냅샷으로 저장하고 저장된 경로를 반환한다."""
    snap_dir  = _get_snapshot_dir(credentials_file)
    snap_path = snap_dir / "audit_snapshot.json"

    snapshot = {
        "created_at":       datetime.now().isoformat(timespec="seconds"),
        "credentials_file": credentials_file,
        "total_accounts":   len(results),
        "accounts": [
            {
                "name":       r["name"],
                "account_id": r.get("account_id"),
                "status":     r["status"],
                "warnings":   r.get("warnings", []),
            }
            for r in results
        ],
    }

    with snap_path.open("w", encoding="utf-8") as f:
        json.dump(snapshot, f, ensure_ascii=False, indent=2)

    return snap_path



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


def _audit_account(cred: dict) -> None:
    """단일 계정의 잔여 리소스를 병렬 스캔한다."""
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
            record_result({"name": account_name, "account_id": account_id, "status": "error", "warnings": []})
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

    remaining = warnings_found

    if remaining:
        log.append(f"  [경고] 발견된 잔여 리소스 ({len(remaining)}건):")
        for w in sorted(set(remaining)):
            log.append(f"    - {w}")
    else:
        log.append("  [성공] 잔여 리소스 없음 — 계정이 깨끗합니다.")

    status = "clean" if not remaining else "has_resources"
    log += [f"  [{account_name}] 검사 완료", f"{'='*60}"]
    flush_log(log)
    record_result({
        "name":       account_name,
        "account_id": account_id,
        "status":     status,
        "warnings":   list(set(remaining)),
    })


# ── 요약 출력 ─────────────────────────────────────────────────────────────────

def _print_audit_summary(total: int) -> None:
    results  = get_results()
    clean    = [r for r in results if r["status"] == "clean"]
    has_res  = [r for r in results if r["status"] == "has_resources"]
    errors   = [r for r in results if r["status"] == "error"]

    lines = ["", "=" * 60, f"  [최종 감사 요약]", "=" * 60,
             f"  전체 계정 수          : {total}개",
             f"  깨끗한 계정           : {len(clean)}개",
             f"  잔여 리소스 있음      : {len(has_res)}개",
             f"  검사 오류             : {len(errors)}개"]

    if has_res:
        lines += ["", "=" * 60, "  [잔여 리소스 발견 계정]", "=" * 60]
        for r in sorted(has_res, key=account_sort_key):
            lines.append(f"  {r['name']:<10}  계정 ID: {r.get('account_id', 'N/A')}  ({len(r['warnings'])}건)")
            for w in sorted(r["warnings"]):
                lines.append(f"    └ {w}")

    lines += ["", "  ※ 리소스를 삭제하려면 awsw clean 을 사용하세요."]
    lines.append("=" * 60)
    print("\n".join(lines))


# ── click 커맨드 ───────────────────────────────────────────────────────────────

@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
def cmd(credentials_file, account_filter):
    """잔여 리소스 스캔 및 스냅샷 저장. 삭제는 awsw clean 을 사용하세요."""
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    click.echo(f"AWS 리소스 감사 시작 — 총 {len(creds)}개 계정\n")
    regions = _fetch_regions(creds[0])
    enriched_creds = [{**c, "_regions": regions} for c in creds]
    clear_results()
    run_parallel(_audit_account, enriched_creds)
    _print_audit_summary(len(creds))

    # 스냅샷 저장 (기존 파일은 이력으로 회전)
    _rotate_snapshot(credentials_file)
    snap_path = _save_snapshot(credentials_file, get_results())
    click.echo(f"\n스냅샷 저장: {snap_path}")
    click.echo("\n모든 계정 검사 완료. 삭제하려면: awsw clean")
