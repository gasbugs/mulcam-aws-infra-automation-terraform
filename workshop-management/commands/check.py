# =============================================================================
# commands/check.py
# awsw check — CloudFront / ALB 서비스 한도 점검
#
# 기존 aws-limit-check.py 의 로직을 click 커맨드로 래핑한다.
# =============================================================================
from __future__ import annotations

import uuid
from collections import Counter

import click
from botocore.exceptions import ClientError

from utils.credentials import filter_credentials, load_credentials
from utils.output import account_sort_key, flush_log, format_output, record_result, clear_results, get_results, set_current_account
from utils.parallel import run_parallel
from utils.session import get_account_id, make_session

REGION = "us-east-1"
CF_LIMIT_KEYWORDS  = ["account must be verified", "contact aws support"]
ALB_LIMIT_KEYWORDS = ["does not support creating load balancers"]


# ── 한도 확인 헬퍼 ─────────────────────────────────────────────────────────────

def _is_limit_error(message: str, keywords: list) -> bool:
    msg_lower = message.lower()
    return any(kw.lower() in msg_lower for kw in keywords)


def _check_cloudfront(session, log: list) -> str:
    """최소 설정으로 CloudFront 배포 생성을 시도해 계정 제한 여부를 판별한다.
    반환값: 'ok' | 'limited' | 'unknown'"""
    cf = session.client("cloudfront")
    caller_ref = f"limit-check-{uuid.uuid4().hex[:8]}"
    try:
        resp = cf.create_distribution(DistributionConfig={
            "CallerReference": caller_ref, "Comment": "limit-check (auto-delete)",
            "Enabled": False,
            "Origins": {"Quantity": 1, "Items": [{"Id": "origin-1", "DomainName": "example.com",
                         "CustomOriginConfig": {"HTTPPort": 80, "HTTPSPort": 443,
                                                "OriginProtocolPolicy": "https-only"}}]},
            "DefaultCacheBehavior": {"TargetOriginId": "origin-1",
                                     "ViewerProtocolPolicy": "redirect-to-https",
                                     "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
                                     "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
        })
        dist_id = resp["Distribution"]["Id"]
        log.append(f"  [CloudFront] 생성 성공 — 즉시 삭제 중 (ID: {dist_id})")
        try:
            cfg = cf.get_distribution_config(Id=dist_id)
            cfg["DistributionConfig"]["Enabled"] = False
            cf.update_distribution(Id=dist_id, DistributionConfig=cfg["DistributionConfig"], IfMatch=cfg["ETag"])
        except ClientError:
            pass
        try:
            etag = cf.get_distribution(Id=dist_id)["ETag"]
            cf.delete_distribution(Id=dist_id, IfMatch=etag)
            log.append("  [CloudFront] 삭제 완료")
        except ClientError as e:
            log.append(f"  [CloudFront] 삭제 실패 (수동 삭제 필요): {e}")
        return "ok"
    except ClientError as e:
        msg = e.response["Error"].get("Message", "")
        code = e.response["Error"].get("Code", "")
        if _is_limit_error(msg, CF_LIMIT_KEYWORDS):
            log.append(f"  [CloudFront] 제한 감지: {msg}")
            return "limited"
        if code in ("MalformedInput", "InvalidArgument", "NoSuchCachePolicy"):
            log.append(f"  [CloudFront] 설정 오류 — 계정 제한 없음 ({code})")
            return "ok"
        log.append(f"  [CloudFront] 확인 불가 ({code}): {msg}")
        return "unknown"


def _check_alb(session, log: list) -> str:
    """기본 VPC 서브넷에 ALB 생성을 시도해 계정 제한 여부를 판별한다.
    반환값: 'ok' | 'limited' | 'unknown'"""
    ec2 = session.client("ec2", region_name=REGION)
    try:
        vpcs = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])["Vpcs"]
        if not vpcs:
            log.append("  [ALB] 기본 VPC 없음 — 서브넷 조회 불가")
            return "unknown"
        vpc_id = vpcs[0]["VpcId"]
        subnets = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["Subnets"]
        seen_az: dict = {}
        for s in subnets:
            az = s["AvailabilityZone"]
            if az not in seen_az:
                seen_az[az] = s["SubnetId"]
            if len(seen_az) >= 2:
                break
        if len(seen_az) < 2:
            log.append("  [ALB] AZ가 2개 미만 — 서브넷 부족")
            return "unknown"
        subnet_ids = list(seen_az.values())
    except ClientError as e:
        log.append(f"  [ALB] 서브넷 조회 실패: {e}")
        return "unknown"

    elb = session.client("elbv2", region_name=REGION)
    try:
        resp = elb.create_load_balancer(
            Name=f"lc-{uuid.uuid4().hex[:8]}", Subnets=subnet_ids,
            Type="application", Scheme="internet-facing",
        )
        lb_arn = resp["LoadBalancers"][0]["LoadBalancerArn"]
        log.append("  [ALB] 생성 성공 — 즉시 삭제 중")
        try:
            elb.delete_load_balancer(LoadBalancerArn=lb_arn)
            log.append("  [ALB] 삭제 완료")
        except ClientError as e:
            log.append(f"  [ALB] 삭제 실패 (수동 삭제 필요): {e}")
        return "ok"
    except ClientError as e:
        msg = e.response["Error"].get("Message", "")
        code = e.response["Error"].get("Code", "")
        if _is_limit_error(msg, ALB_LIMIT_KEYWORDS):
            log.append(f"  [ALB] 제한 감지: {msg}")
            return "limited"
        log.append(f"  [ALB] 확인 불가 ({code}): {msg}")
        return "unknown"


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def _check_account(cred: dict) -> None:
    set_current_account(cred["name"])  # 지연 출력 모드에서 계정 로그 버퍼 연결
    account_name = cred["name"]
    log = [f"{'='*60}", f"  [{account_name} / Key: {cred['access_key'][:5]}...] 한도 확인 시작"]

    session = make_session(cred["access_key"], cred["secret_key"])
    account_id = get_account_id(session)
    if not account_id:
        log += ["  [오류] 계정 ID 조회 실패", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": None, "cf": "error", "alb": "error", "status": "error"})
        return

    log.append(f"  계정 ID: {account_id}")
    cf_result  = _check_cloudfront(session, log)
    alb_result = _check_alb(session, log)

    label = {"ok": "[정상]", "limited": "[제한]", "unknown": "[확인불가]", "error": "[오류]"}
    log.append(f"  결과 → CloudFront: {label.get(cf_result, cf_result)}  /  ALB: {label.get(alb_result, alb_result)}")
    log.append(f"{'='*60}")
    flush_log(log)

    status = "limited" if "limited" in (cf_result, alb_result) else "ok"
    record_result({"name": account_name, "account_id": account_id,
                   "cf": cf_result, "alb": alb_result, "status": status})


# ── 요약 출력 ─────────────────────────────────────────────────────────────────

def _print_check_summary(total: int) -> None:
    results = get_results()
    cf_counter  = Counter(r["cf"]  for r in results)
    alb_counter = Counter(r["alb"] for r in results)
    label = {"ok": "정상", "limited": "제한", "unknown": "확인불가", "error": "오류"}

    lines = ["", "=" * 60, "  [최종 통계 요약]", "=" * 60,
             f"  전체 계정 수 : {total}개",
             "  ─────────────────────────────────────",
             "  CloudFront"]
    for status in ("ok", "limited", "unknown", "error"):
        if cnt := cf_counter.get(status, 0):
            lines.append(f"    · {label[status]:<8} : {cnt}개")
    lines += ["  ─────────────────────────────────────", "  ALB (us-east-1)"]
    for status in ("ok", "limited", "unknown", "error"):
        if cnt := alb_counter.get(status, 0):
            lines.append(f"    · {label[status]:<8} : {cnt}개")

    limited = sorted([r for r in results if r["cf"] == "limited" or r["alb"] == "limited"],
                     key=account_sort_key)
    if limited:
        lines += ["", "=" * 60, "  [제한 발생 계정 목록]  (AWS Support 문의 필요)", "=" * 60]
        for r in limited:
            cf_lbl  = "제한" if r["cf"]  == "limited" else "-"
            alb_lbl = "제한" if r["alb"] == "limited" else "-"
            lines.append(f"  {r['name']:<10}  계정 ID: {r['account_id']}  "
                         f"CloudFront: {cf_lbl:4}  ALB: {alb_lbl}")
    else:
        lines.append("  [확인] 제한 발생 계정 없음")
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
def cmd(credentials_file, account_filter, output_fmt):
    """CloudFront / ALB 서비스 한도 점검."""
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    click.echo(f"AWS 서비스 한도 확인 시작 — 총 {len(creds)}개 계정\n")
    clear_results()
    run_parallel(_check_account, creds)

    if output_fmt == "table":
        _print_check_summary(len(creds))
    else:
        format_output(get_results(), fmt=output_fmt, title="서비스 한도 점검")
    click.echo("\n모든 계정 확인 완료.")
