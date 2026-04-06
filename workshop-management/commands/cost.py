# =============================================================================
# commands/cost.py
# awsw cost — 전일(또는 지정일) 비용 리포트
#
# 기존 aws-daily-cost-report.py 의 로직을 click 커맨드로 래핑한다.
# =============================================================================
from __future__ import annotations

import json
from collections import Counter
from datetime import date, datetime, timedelta

import click
from botocore.exceptions import ClientError

from utils.credentials import filter_credentials, load_credentials
from utils.output import account_sort_key, flush_log, format_output, record_result, clear_results, get_results, set_current_account
from utils.parallel import run_parallel
from utils.session import get_account_id, make_session

CE_REGION = "us-east-1"
COST_REPORTER_USER = "terraform-user-0"
COST_REPORTER_POLICY = "CostExplorerReadOnly"


# ── IAM 헬퍼 ──────────────────────────────────────────────────────────────────

def _ensure_cost_reporter(iam, log: list) -> bool:
    """terraform-user-0 를 생성/확인하고 Cost Explorer 읽기 권한을 부여한다."""
    try:
        iam.get_user(UserName=COST_REPORTER_USER)
        log.append(f"  [확인] 사용자 이미 존재: {COST_REPORTER_USER}")
    except iam.exceptions.NoSuchEntityException:
        try:
            iam.create_user(UserName=COST_REPORTER_USER)
            log.append(f"  [생성] 사용자 생성 완료: {COST_REPORTER_USER}")
        except ClientError as e:
            log.append(f"  [오류] 사용자 생성 실패: {e}")
            return False

    ce_policy = json.dumps({
        "Version": "2012-10-17",
        "Statement": [{"Sid": "AllowCostExplorerRead", "Effect": "Allow",
                        "Action": ["ce:GetCostAndUsage", "ce:GetCostForecast",
                                   "ce:GetDimensionValues", "ce:GetTags"],
                        "Resource": "*"}],
    })
    try:
        iam.put_user_policy(UserName=COST_REPORTER_USER,
                            PolicyName=COST_REPORTER_POLICY, PolicyDocument=ce_policy)
        log.append(f"  [설정] Cost Explorer 읽기 권한 부여 완료")
    except ClientError as e:
        log.append(f"  [오류] 권한 부여 실패: {e}")
        return False
    return True


def _verify_ce_permission(session, iam, log: list) -> bool:
    """iam:SimulatePrincipalPolicy 로 ce:GetCostAndUsage 권한이 허용되는지 검증한다."""
    try:
        caller_arn = session.client("sts").get_caller_identity()["Arn"]
        result = iam.simulate_principal_policy(
            PolicySourceArn=caller_arn,
            ActionNames=["ce:GetCostAndUsage"],
            ResourceArns=["*"],
        )
        eval_result = result["EvaluationResults"][0]
        decision = eval_result["EvalDecision"]
        if decision == "allowed":
            log.append(f"  [확인] ce:GetCostAndUsage 권한 시뮬레이션: {decision}")
            return True

        reasons = []
        if not eval_result.get("PermissionsBoundaryDecisionDetail", {}).get("AllowedByPermissionsBoundary", True):
            reasons.append("Permission Boundary 차단")
        if not eval_result.get("OrganizationsDecisionDetail", {}).get("AllowedByOrganizations", True):
            reasons.append("SCP(Organizations) 차단")
        if not reasons:
            reasons.append("정책 미부여 또는 명시적 Deny")
        log.append(f"  [경고] ce:GetCostAndUsage 시뮬레이션 결과: {decision} — 원인: {', '.join(reasons)}")
        return False
    except ClientError:
        log.append("  [정보] 권한 시뮬레이션 불가 — CE 호출을 직접 시도합니다.")
        return True


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def _check_cost(cred: dict, period: dict) -> None:
    """단일 계정의 지정 기간 비용을 조회하고 결과를 기록한다."""
    set_current_account(cred["name"])  # 지연 출력 모드에서 계정 로그 버퍼 연결
    account_name = cred["name"]
    log = [f"{'='*60}", f"  [{account_name} / Key: {cred['access_key'][:5]}...] 비용 조회 ({period['Start']})"]

    session = make_session(cred["access_key"], cred["secret_key"])
    account_id = get_account_id(session)
    if not account_id:
        log += ["  [오류] 계정 ID 조회 실패", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": None,
                       "status": "error", "error_reason": "자격증명 오류",
                       "total_usd": None, "billed_services": []})
        return

    log.append(f"  계정 ID: {account_id}")
    iam = session.client("iam")

    if not _ensure_cost_reporter(iam, log):
        log += [f"  [{account_name}] 조회 중단 (권한 설정 실패)", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": "IAM 권한 설정 실패",
                       "total_usd": None, "billed_services": []})
        return

    if not _verify_ce_permission(session, iam, log):
        log += [f"  [{account_name}] 조회 중단 (ce:GetCostAndUsage 권한 부족)", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": "CE 권한 부족 (SCP/Boundary)",
                       "total_usd": None, "billed_services": []})
        return

    try:
        ce = session.client("ce", region_name=CE_REGION)
        response = ce.get_cost_and_usage(
            TimePeriod=period, Granularity="DAILY", Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
    except ClientError as e:
        code = e.response["Error"]["Code"]
        log += [f"  [오류] Cost Explorer API 호출 실패: {e}", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": f"CE API 오류 ({code})",
                       "total_usd": None, "billed_services": []})
        return

    groups = (response.get("ResultsByTime") or [{}])[0].get("Groups", [])
    total_usd = 0.0
    billed_services = []
    for group in groups:
        amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
        if round(amount, 4) > 0:
            billed_services.append((group["Keys"][0], amount,
                                    group["Metrics"]["UnblendedCost"]["Unit"]))
            total_usd += amount

    if not billed_services:
        log.append("  [성공] 어제 발생한 비용 없음 ($0.00)")
    else:
        log.append(f"  [경고] 비용 발생 — 합계: ${total_usd:.4f} USD")
        for svc, amt, unit in sorted(billed_services, key=lambda x: x[1], reverse=True):
            bar = "█" * min(int(amt / total_usd * 20), 20)
            log.append(f"    {bar:<20}  ${amt:>10.4f} {unit}  {svc}")

    log += [f"  [{account_name}] 조회 완료", f"{'='*60}"]
    flush_log(log)
    record_result({"name": account_name, "account_id": account_id,
                   "status": "ok", "total_usd": total_usd, "billed_services": billed_services})


# ── 요약 출력 ─────────────────────────────────────────────────────────────────

def _print_cost_summary(total_accounts: int) -> None:
    results = get_results()
    ok = [r for r in results if r["status"] == "ok"]
    errors = [r for r in results if r["status"] == "error"]
    with_cost = [r for r in ok if (r["total_usd"] or 0) > 0]

    lines = ["", "=" * 60, "  [최종 통계 요약]", "=" * 60,
             f"  전체 계정 수     : {total_accounts}개",
             f"  조회 성공        : {len(ok)}개",
             f"  조회 실패/오류   : {len(errors)}개"]

    if ok:
        zero = len(ok) - len(with_cost)
        lines += [f"  $0 (정상)        : {zero}개",
                  f"  비용 발생 (주의) : {len(with_cost)}개",
                  f"  전체 비용 합계   : ${sum(r['total_usd'] for r in ok):.4f} USD"]

    if with_cost:
        lines += ["", "=" * 60, "  [삭제 조치 필요 계정]", "=" * 60]
        for r in sorted(with_cost, key=account_sort_key):
            lines.append(f"  {r['name']:<10}  계정 ID: {r['account_id']}  합계: ${r['total_usd']:.4f} USD")
            for svc, amt, unit in sorted(r["billed_services"], key=lambda x: x[1], reverse=True):
                lines.append(f"    └ ${amt:.4f} {unit}  {svc}")
    else:
        lines.append("  [확인] 삭제 조치가 필요한 계정 없음")

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
@click.option("--date", "target_date", default=None,
              help="조회 날짜 (YYYY-MM-DD, 기본값: 전일)")
def cmd(credentials_file, account_filter, output_fmt, target_date):
    """전일 비용 리포트 (서비스별 비용 조회)."""
    # 조회 날짜 계산
    if target_date:
        try:
            query_date = datetime.strptime(target_date, "%Y-%m-%d").date()
        except ValueError:
            click.echo("오류: --date 형식이 잘못되었습니다. (예: 2026-04-05)", err=True)
            raise SystemExit(1)
    else:
        query_date = date.today() - timedelta(days=1)

    period = {
        "Start": query_date.strftime("%Y-%m-%d"),
        "End": (query_date + timedelta(days=1)).strftime("%Y-%m-%d"),
    }

    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    # Cost Explorer API는 호출 1회당 $0.01이 청구된다.
    account_count = len(creds)
    api_cost = account_count * 0.01
    click.echo(f"AWS 워크샵 비용 리포트 (조회 날짜: {period['Start']})")
    click.echo(f"")
    click.echo(f"  대상 계정 수  : {account_count}개")
    click.echo(f"  API 호출 비용 : {account_count}개 × $0.01 = ${api_cost:.2f} USD 발생 예정")
    click.echo(f"")
    if not click.confirm("  계속 진행하시겠습니까?", default=False):
        click.echo("취소되었습니다.")
        return
    click.echo("")

    clear_results()
    from functools import partial
    run_parallel(partial(_check_cost, period=period), creds)

    if output_fmt == "table":
        _print_cost_summary(len(creds))
    else:
        format_output(get_results(), fmt=output_fmt, title="비용 리포트")

    click.echo("\n모든 계정 조회 완료.")
