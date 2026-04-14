# =============================================================================
# commands/clean.py
# awsw clean — 스냅샷 기반 잔여 리소스 삭제
#
# audit 명령이 저장한 snapshots/audit_snapshot.json 을 읽어 발견된
# 리소스를 삭제하고, 결과를 snapshots/clean_history.json 에 기록한다.
# =============================================================================
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

import click
from botocore.exceptions import ClientError

from utils.credentials import filter_credentials, load_credentials
from utils.output import (
    account_sort_key, clear_results, flush_log, get_results,
    record_result, set_current_account,
)
from utils.parallel import run_parallel
from utils.session import make_session

# ── cleaners 서브모듈 import ───────────────────────────────────────────────────
from commands.cleaners.compute import (
    perform_ami_cleanup, perform_asg_cleanup,
    perform_ebs_snapshot_cleanup, perform_ebs_volume_cleanup,
    perform_ec2_cleanup, perform_ecs_full_cleanup,
    perform_ecs_task_def_cleanup,
    perform_eks_full_cleanup, perform_lambda_cleanup,
)
from commands.cleaners.database import (
    perform_dynamodb_cleanup, perform_elasticache_cleanup, perform_rds_cleanup,
)
from commands.cleaners.iam import perform_iam_cleanup
from commands.cleaners.misc import (
    perform_acm_cleanup, perform_apigateway_cleanup,
    perform_cloudwatch_alarm_cleanup, perform_cloudwatch_cleanup,
    perform_codebuild_cleanup, perform_codecommit_cleanup,
    perform_codepipeline_cleanup, perform_imagebuilder_cleanup,
    perform_kms_cleanup, perform_secretsmanager_cleanup,
    perform_sns_cleanup, perform_sqs_cleanup, perform_wafv2_cleanup,
)
from commands.cleaners.network import (
    perform_cloudfront_cleanup, perform_eip_cleanup,
    perform_elb_cleanup, perform_nat_gateway_cleanup,
    perform_route53_cleanup, perform_sg_cleanup, perform_vpc_cleanup,
)
from commands.cleaners.storage import (
    perform_backup_cleanup, perform_ecr_cleanup, perform_efs_cleanup,
    perform_keypair_cleanup, perform_rds_snapshot_cleanup, perform_s3_cleanup,
)


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
        "ecs_cleanup", "ecs_task_def_cleanup", "eks_cleanup", "asg_cleanup", "elb_cleanup",
        "rds_cleanup", "elasticache_cleanup", "efs_cleanup",
        "secretsmanager_cleanup", "codebuild_cleanup", "wafv2_cleanup",
        "backup_cleanup", "dynamodb_cleanup", "sns_cleanup", "sqs_cleanup",
        "acm_cleanup", "route53_cleanup", "keypair_cleanup", "kms_cleanup",
        "nat_gw_cleanup", "sg_cleanup", "ecr_cleanup",
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


def _save_residual_snapshot(
    credentials_file: str,
    original_snapshot: dict,
    failed_names: set[str],
) -> Path:
    """삭제 실패 계정만 걸러서 잔여 스냅샷으로 저장한다.
    저장 후 awsw clean 을 재실행하면 실패 계정만 대상으로 재시도할 수 있다."""
    residual_accounts = [
        a for a in original_snapshot["accounts"]
        if a["name"] in failed_names
    ]
    snap_path = _get_snapshot_dir(credentials_file) / "audit_snapshot.json"
    residual = {
        "created_at":       original_snapshot.get("created_at", "unknown"),
        "credentials_file": credentials_file,
        "total_accounts":   len(residual_accounts),
        "accounts":         residual_accounts,
    }
    with snap_path.open("w", encoding="utf-8") as f:
        json.dump(residual, f, ensure_ascii=False, indent=2)
    return snap_path


# ── 단일 계정 삭제 오케스트레이터 ─────────────────────────────────────────────

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
                           "ecs_cleanup": {}, "ecs_task_def_cleanup": {}, "eks_cleanup": {}, "asg_cleanup": {},
                           "elb_cleanup": {}, "rds_cleanup": {}, "elasticache_cleanup": {},
                           "efs_cleanup": {}, "secretsmanager_cleanup": {},
                           "codebuild_cleanup": {}, "wafv2_cleanup": {},
                           "backup_cleanup": {}, "dynamodb_cleanup": {},
                           "sns_cleanup": {}, "sqs_cleanup": {},
                           "acm_cleanup": {}, "route53_cleanup": {},
                           "keypair_cleanup": {}, "kms_cleanup": {},
                           "nat_gw_cleanup": {}, "sg_cleanup": {},
                           "ecr_cleanup": {}})
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
        "ecs_cleanup":             _found("ECS Clusters"),
        # 클러스터 없이 태스크 정의만 남은 경우 또는 클러스터 정리 후 잔여 태스크 정의 처리
        "ecs_task_def_cleanup":    _found("ECS Task Definitions") or _found("ECS Clusters"),
        "ecr_cleanup":             _found("ECR"),
        "eks_cleanup":             _found("EKS"),
        "asg_cleanup":             _found("AutoScalingGroups"),
        "elb_cleanup":             _found("ELB"),
        "rds_cleanup":             _found("RDS 리소스"),  # "RDS Snapshots 리소스"와 구분하기 위해 "RDS 리소스"로 매칭
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
        "sg_cleanup":              _found("Security Groups"),
        "nat_gw_cleanup":          _found("NAT Gateway"),
        "vpc_cleanup":             _found("VPC"),
        "kms_cleanup":             _found("KMS"),
    }

    # 실행할 작업만 필터링 (순서 유지: 의존 관계 반영)
    ALL_OPS = [
        ("codepipeline_cleanup",    lambda: perform_codepipeline_cleanup(session, log, regions),     "CodePipeline 삭제 중"),
        ("lambda_cleanup",          lambda: perform_lambda_cleanup(session, log, regions),           "Lambda 삭제 중"),
        ("apigateway_cleanup",      lambda: perform_apigateway_cleanup(session, log, regions),       "API Gateway 삭제 중"),
        ("cw_alarm_cleanup",        lambda: perform_cloudwatch_alarm_cleanup(session, log, regions), "CloudWatch 알람 삭제 중"),
        ("cloudwatch_cleanup",      lambda: perform_cloudwatch_cleanup(session, log, regions),       "CloudWatch 로그 그룹 삭제 중"),
        ("ecs_cleanup",             lambda: perform_ecs_full_cleanup(session, log, regions),         "ECS 정리 중"),
        # ECS 클러스터 정리 후 고아 태스크 정의가 남아 있을 수 있으므로 별도 실행
        ("ecs_task_def_cleanup",    lambda: perform_ecs_task_def_cleanup(session, log, regions),     "ECS 태스크 정의 정리 중"),
        ("eks_cleanup",             lambda: perform_eks_full_cleanup(session, log, regions),         "EKS 정리 중"),
        # ECR은 ECS·EKS가 이미지를 더 이상 참조하지 않는 상태에서 삭제
        ("ecr_cleanup",             lambda: perform_ecr_cleanup(session, log, regions),              "ECR 리포지토리 삭제 중"),
        ("asg_cleanup",             lambda: perform_asg_cleanup(session, log, regions),              "ASG 삭제 중"),
        ("elb_cleanup",             lambda: perform_elb_cleanup(session, log, regions),              "ELB 삭제 중"),
        ("rds_cleanup",             lambda: perform_rds_cleanup(session, log, regions),              "RDS 인스턴스/클러스터 삭제 중"),
        ("elasticache_cleanup",     lambda: perform_elasticache_cleanup(session, log, regions),      "ElastiCache 삭제 중"),
        ("efs_cleanup",             lambda: perform_efs_cleanup(session, log, regions),              "EFS 삭제 중"),
        ("secretsmanager_cleanup",  lambda: perform_secretsmanager_cleanup(session, log, regions),   "Secrets Manager 삭제 중"),
        ("codebuild_cleanup",       lambda: perform_codebuild_cleanup(session, log, regions),        "CodeBuild 삭제 중"),
        # CloudFront를 WAFv2보다 먼저 삭제해야 한다 — CreatedByCloudFront-* WAF ACL은
        # CloudFront 배포와 연결된 상태에서 삭제하면 실패하므로 CF 삭제 후 WAFv2를 정리한다
        ("cf_cleanup",              lambda: perform_cloudfront_cleanup(session, log),                "CloudFront 정리 중"),
        ("wafv2_cleanup",           lambda: perform_wafv2_cleanup(session, log, regions),            "WAFv2 삭제 중"),
        ("backup_cleanup",          lambda: perform_backup_cleanup(session, log, regions),           "Backup 볼트 삭제 중"),
        ("dynamodb_cleanup",        lambda: perform_dynamodb_cleanup(session, log, regions),         "DynamoDB 삭제 중"),
        ("sns_cleanup",             lambda: perform_sns_cleanup(session, log, regions),              "SNS 삭제 중"),
        ("sqs_cleanup",             lambda: perform_sqs_cleanup(session, log, regions),              "SQS 삭제 중"),
        ("iam_cleanup",             lambda: perform_iam_cleanup(session, log),                       "IAM 정리 중"),
        ("acm_cleanup",             lambda: perform_acm_cleanup(session, log, regions),              "ACM 인증서 삭제 중"),
        ("ami_cleanup",             lambda: perform_ami_cleanup(session, log, regions),              "AMI 정리 중"),
        ("snap_cleanup",            lambda: perform_ebs_snapshot_cleanup(session, log, regions),     "EBS 스냅샷 삭제 중"),
        ("rds_snap_cleanup",        lambda: perform_rds_snapshot_cleanup(session, log, regions),     "RDS 스냅샷 삭제 중"),
        # Image Builder 의존 순서: 파이프라인 → 레시피 → 컴포넌트 → 인프라/배포 설정
        ("imagebuilder_cleanup",    lambda: perform_imagebuilder_cleanup(session, log, regions),     "Image Builder 정리 중"),
        ("codecommit_cleanup",      lambda: perform_codecommit_cleanup(session, log, regions),       "CodeCommit 정리 중"),
        ("s3_cleanup",              lambda: perform_s3_cleanup(session, log),                        "S3 버킷 삭제 중"),
        ("route53_cleanup",         lambda: perform_route53_cleanup(session, log),                   "Route53 정리 중"),
        ("ec2_cleanup",             lambda: perform_ec2_cleanup(session, log, regions),              "EC2 종료 중"),
        ("keypair_cleanup",         lambda: perform_keypair_cleanup(session, log, regions),          "Key Pair 삭제 중"),
        ("eip_cleanup",             lambda: perform_eip_cleanup(session, log, regions),              "EIP 해제 중"),
        ("ebs_cleanup",             lambda: perform_ebs_volume_cleanup(session, log, regions),       "EBS 볼륨 삭제 중"),
        # SG는 EC2·ELB·ECS 정리 후, VPC 삭제 전에 실행 — 상호 참조 규칙 제거 후 삭제
        ("sg_cleanup",              lambda: perform_sg_cleanup(session, log, regions),               "Security Group 삭제 중"),
        # NAT GW는 VPC 삭제 전에 먼저 제거해야 서브넷이 지워짐 — EIP도 함께 해제
        ("nat_gw_cleanup",          lambda: perform_nat_gateway_cleanup(session, log, regions),      "NAT Gateway 삭제 중"),
        ("vpc_cleanup",             lambda: perform_vpc_cleanup(session, log, regions),              "VPC 삭제 중"),
        ("kms_cleanup",             lambda: perform_kms_cleanup(session, log, regions),              "KMS 삭제 예약 중"),
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
    """삭제 단계 결과 요약을 출력한다.
    성공 항목과 실패 항목을 분리해서 표시하고, 실패는 빨간 글씨로 강조한다."""
    results = get_results()
    def _sum(key, sub): return sum(len(r.get(key, {}).get(sub, [])) for r in results)

    # (섹션명, 성공 레이블, 성공 수, 실패 레이블, 실패 수, 참고 [(레이블, 수)])
    # 성공/실패 레이블은 동사에 맞게 구분 (삭제·종료·해제·해지·예약)
    SECTIONS = [
        ("CodePipeline",    "삭제 완료", _sum("codepipeline_cleanup",  "deleted"),
                            "삭제 실패", _sum("codepipeline_cleanup",  "failed"),   []),
        ("Lambda",          "삭제 완료", _sum("lambda_cleanup",        "deleted"),
                            "삭제 실패", _sum("lambda_cleanup",        "failed"),   []),
        ("API Gateway",     "삭제 완료", _sum("apigateway_cleanup",    "deleted"),
                            "삭제 실패", _sum("apigateway_cleanup",    "failed"),   []),
        ("CW 알람",         "삭제 완료", _sum("cw_alarm_cleanup",      "deleted"),
                            "삭제 실패", _sum("cw_alarm_cleanup",      "failed"),   []),
        ("CloudWatch",      "삭제 완료", _sum("cloudwatch_cleanup",    "deleted"),
                            "삭제 실패", _sum("cloudwatch_cleanup",    "failed"),   []),
        ("ECS",             "삭제 완료", _sum("ecs_cleanup",           "deleted"),
                            "삭제 실패", _sum("ecs_cleanup",           "failed"),   []),
        ("ECS 태스크 정의", "삭제 완료", _sum("ecs_task_def_cleanup",  "deleted"),
                            "삭제 실패", _sum("ecs_task_def_cleanup",  "failed"),   []),
        ("EKS",             "삭제 완료", _sum("eks_cleanup",           "deleted"),
                            "삭제 실패", _sum("eks_cleanup",           "failed"),   []),
        ("ECR",             "삭제 완료", _sum("ecr_cleanup",           "deleted"),
                            "삭제 실패", _sum("ecr_cleanup",           "failed"),   []),
        ("ASG",             "삭제 완료", _sum("asg_cleanup",           "deleted"),
                            "삭제 실패", _sum("asg_cleanup",           "failed"),   []),
        ("ELB",             "삭제 완료", _sum("elb_cleanup",           "deleted"),
                            "삭제 실패", _sum("elb_cleanup",           "failed"),   []),
        ("RDS",             "삭제 완료", _sum("rds_cleanup",           "deleted"),
                            "삭제 실패", _sum("rds_cleanup",           "failed"),   []),
        ("ElastiCache",     "삭제 완료", _sum("elasticache_cleanup",   "deleted"),
                            "삭제 실패", _sum("elasticache_cleanup",   "failed"),   []),
        ("EFS",             "삭제 완료", _sum("efs_cleanup",           "deleted"),
                            "삭제 실패", _sum("efs_cleanup",           "failed"),   []),
        ("Secrets Manager", "삭제 완료", _sum("secretsmanager_cleanup","deleted"),
                            "삭제 실패", _sum("secretsmanager_cleanup","failed"),   []),
        ("CodeBuild",       "삭제 완료", _sum("codebuild_cleanup",     "deleted"),
                            "삭제 실패", _sum("codebuild_cleanup",     "failed"),   []),
        ("WAFv2",           "삭제 완료", _sum("wafv2_cleanup",         "deleted"),
                            "삭제 실패", _sum("wafv2_cleanup",         "failed"),   []),
        ("Backup",          "삭제 완료", _sum("backup_cleanup",        "deleted"),
                            "삭제 실패", _sum("backup_cleanup",        "failed"),   []),
        ("DynamoDB",        "삭제 완료", _sum("dynamodb_cleanup",      "deleted"),
                            "삭제 실패", _sum("dynamodb_cleanup",      "failed"),   []),
        ("SNS",             "삭제 완료", _sum("sns_cleanup",           "deleted"),
                            "삭제 실패", _sum("sns_cleanup",           "failed"),   []),
        ("SQS",             "삭제 완료", _sum("sqs_cleanup",           "deleted"),
                            "삭제 실패", _sum("sqs_cleanup",           "failed"),   []),
        ("IAM",             "삭제 완료", _sum("iam_cleanup",           "deleted"),
                            "삭제 실패", _sum("iam_cleanup",           "failed"),   []),
        ("ACM",             "삭제 완료", _sum("acm_cleanup",           "deleted"),
                            "삭제 실패", _sum("acm_cleanup",           "failed"),   []),
        ("Image Builder",   "삭제 완료", _sum("imagebuilder_cleanup",  "deleted"),
                            "삭제 실패", _sum("imagebuilder_cleanup",  "failed"),   []),
        ("CodeCommit",      "삭제 완료", _sum("codecommit_cleanup",    "deleted"),
                            "삭제 실패", _sum("codecommit_cleanup",    "failed"),   []),
        ("S3 버킷",         "삭제 완료", _sum("s3_cleanup",            "deleted"),
                            "삭제 실패", _sum("s3_cleanup",            "failed"),   []),
        ("Route53",         "삭제 완료", _sum("route53_cleanup",       "deleted"),
                            "삭제 실패", _sum("route53_cleanup",       "failed"),   []),
        ("EC2 인스턴스",    "종료 완료", _sum("ec2_cleanup",           "terminated"),
                            "종료 실패", _sum("ec2_cleanup",           "failed"),   []),
        ("Key Pair",        "삭제 완료", _sum("keypair_cleanup",       "deleted"),
                            "삭제 실패", _sum("keypair_cleanup",       "failed"),   []),
        ("EIP",             "해제 완료", _sum("eip_cleanup",           "released"),
                            "해제 실패", _sum("eip_cleanup",           "failed"),   []),
        ("EBS 볼륨",        "삭제 완료", _sum("ebs_cleanup",           "deleted"),
                            "삭제 실패", _sum("ebs_cleanup",           "failed"),   []),
        ("AMI",             "해지 완료", _sum("ami_cleanup",           "deregistered"),
                            "해지 실패", _sum("ami_cleanup",           "failed"),   []),
        ("EBS 스냅샷",      "삭제 완료", _sum("snap_cleanup",          "deleted"),
                            "삭제 실패", _sum("snap_cleanup",          "failed"),   []),
        ("RDS 스냅샷",      "삭제 완료", _sum("rds_snap_cleanup",      "deleted"),
                            "삭제 실패", _sum("rds_snap_cleanup",      "failed"),   []),
        ("Security Group",  "삭제 완료", _sum("sg_cleanup",            "deleted"),
                            "삭제 실패", _sum("sg_cleanup",            "failed"),   []),
        ("NAT Gateway",     "삭제 완료", _sum("nat_gw_cleanup",        "deleted"),
                            "삭제 실패", _sum("nat_gw_cleanup",        "failed"),   []),
        ("VPC",             "삭제 완료", _sum("vpc_cleanup",           "deleted"),
                            "삭제 실패", _sum("vpc_cleanup",           "failed"),   []),
        ("KMS",             "삭제 예약", _sum("kms_cleanup",           "deleted"),
                            "예약 실패", _sum("kms_cleanup",           "failed"),   []),
        # CloudFront: 비활성화 요청·스킵은 참고 항목으로 별도 표시
        ("CloudFront",      "삭제 완료", _sum("cf_cleanup",            "deleted"),
                            "삭제 실패", _sum("cf_cleanup",            "failed"),
                            [("비활성화 요청", _sum("cf_cleanup", "disabled")),
                             ("스킵",          _sum("cf_cleanup", "skipped"))]),
    ]

    SEP  = "=" * 60
    SEP2 = "  " + "─" * 56

    # 성공·실패·참고 행 수집
    ok_rows   = []  # (섹션명, 레이블, 수)
    fail_rows = []  # (섹션명, 레이블, 수)
    info_rows = []  # (섹션명, 레이블, 수) — CloudFront 비활성화 등 참고 항목

    for section, ok_lbl, ok_cnt, fail_lbl, fail_cnt, extras in SECTIONS:
        if ok_cnt:
            ok_rows.append((section, ok_lbl, ok_cnt))
        if fail_cnt:
            fail_rows.append((section, fail_lbl, fail_cnt))
        for extra_lbl, extra_cnt in extras:
            if extra_cnt:
                info_rows.append((section, extra_lbl, extra_cnt))

    # 출력
    print(f"\n{SEP}")
    print("  [삭제 결과 요약]")
    print(SEP)

    if not ok_rows and not fail_rows and not info_rows:
        print("  삭제된 리소스 없음")
        print(SEP)
        return

    # ── 삭제 완료 블록 ──────────────────────────────────────────────────────────
    if ok_rows:
        print(f"\n{SEP2}")
        print("  ✔  삭제 완료 항목")
        print(SEP2)
        for section, lbl, cnt in ok_rows:
            print(f"    {section:<20} {lbl:<10} : {cnt}개")

    # ── 삭제 실패 블록 (빨간 글씨) ──────────────────────────────────────────────
    if fail_rows:
        print(f"\n{SEP2}")
        print(click.style("  ✘  삭제 실패 항목", fg="red", bold=True))
        print(SEP2)
        for section, lbl, cnt in fail_rows:
            print(click.style(f"    {section:<20} {lbl:<10} : {cnt}개", fg="red"))

    # ── 참고 항목 블록 (CloudFront 비활성화 등) ─────────────────────────────────
    if info_rows:
        print(f"\n{SEP2}")
        print("  ℹ  참고 항목")
        print(SEP2)
        for section, lbl, cnt in info_rows:
            print(f"    {section:<20} {lbl:<10} : {cnt}개")

    # CloudFront 재실행 안내
    cf_disabled = [r for r in results if r.get("cf_cleanup", {}).get("disabled")]
    if cf_disabled:
        print(f"\n{SEP}")
        print("  [CloudFront 재실행 필요 — 배포 비활성화만 완료]")
        print(SEP)
        for r in sorted(cf_disabled, key=account_sort_key):
            print(f"  {r['name']:<10}  배포 ID: {', '.join(r['cf_cleanup']['disabled'])}")

    print(SEP)


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

    # ── 이력 저장 ────────────────────────────────────────────────────────────
    clean_results = get_results()
    hist_path = _save_clean_history(credentials_file, snapshot_created_at, clean_results)
    click.echo(f"\n삭제 이력 저장: {hist_path}")

    # ── 스냅샷 처리: 실패 계정은 잔여 스냅샷으로 보존, 전부 성공 시 삭제 ────────
    failed_names = {
        r["name"] for r in clean_results
        if any(bool(v.get("failed")) for v in r.values() if isinstance(v, dict))
    }
    if failed_names:
        residual_path = _save_residual_snapshot(credentials_file, snapshot, failed_names)
        click.echo(click.style(
            f"\n[경고] {len(failed_names)}개 계정에 삭제 실패 항목이 남아 있습니다: "
            f"{', '.join(sorted(failed_names))}",
            fg="red", bold=True,
        ))
        click.echo(click.style(
            f"잔여 스냅샷 보존: {residual_path}\n"
            f"awsw clean 을 다시 실행하면 실패 항목만 재시도합니다.",
            fg="yellow",
        ))
    else:
        _delete_snapshot(credentials_file)
        click.echo("스냅샷 파일 삭제 완료.")
