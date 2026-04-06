# =============================================================================
# commands/cost.py
# awsw cost — 전일(또는 지정 기간) 비용 리포트
#
# 기존 aws-daily-cost-report.py 의 로직을 click 커맨드로 래핑한다.
# --date      : 단일 날짜 조회 (기본값: 전일)
# --from/--to : 날짜 범위 조회 (API 1회 호출로 일별 내역 반환)
# =============================================================================
from __future__ import annotations

import csv
import io
import json
from datetime import date, datetime, timedelta
from functools import partial

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

    # 단일 날짜인지 범위인지에 따라 헤더 표시를 다르게 한다
    date_label = (period["Start"] if period["Start"] == period["_display_end"]
                  else f"{period['Start']} ~ {period['_display_end']}")
    log = [f"{'='*60}", f"  [{account_name} / Key: {cred['access_key'][:5]}...] 비용 조회 ({date_label})"]

    session = make_session(cred["access_key"], cred["secret_key"])

    # 자격증명이 terraform-user-1 (수강생 계정)인 경우 실행을 차단한다.
    # Cost Explorer API는 호출당 $0.01이 청구되므로 수강생이 사용하면 안 된다.
    try:
        sts = session.client("sts")
        caller = sts.get_caller_identity()
        caller_arn = caller.get("Arn", "")
        if "terraform-user-1" in caller_arn:
            log += [
                f"  [차단] 비용 문제로 이 기능은 닫혀 있습니다. 관리자에게 문의하세요.",
                f"{'='*60}",
            ]
            flush_log(log)
            record_result({"name": account_name, "account_id": None,
                           "status": "차단", "error_reason": "terraform-user-1 사용 불가",
                           "total_usd": None, "billed_services": [], "daily": []})
            return
        account_id = caller.get("Account")
    except Exception:
        account_id = get_account_id(session)

    if not account_id:
        log += ["  [오류] 계정 ID 조회 실패", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": None,
                       "status": "error", "error_reason": "자격증명 오류",
                       "total_usd": None, "billed_services": [], "daily": []})
        return

    log.append(f"  계정 ID: {account_id}")
    iam = session.client("iam")

    if not _ensure_cost_reporter(iam, log):
        log += [f"  [{account_name}] 조회 중단 (권한 설정 실패)", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": "IAM 권한 설정 실패",
                       "total_usd": None, "billed_services": [], "daily": []})
        return

    if not _verify_ce_permission(session, iam, log):
        log += [f"  [{account_name}] 조회 중단 (ce:GetCostAndUsage 권한 부족)", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": "CE 권한 부족 (SCP/Boundary)",
                       "total_usd": None, "billed_services": [], "daily": []})
        return

    # CE API에 전달할 period는 Start/End만 사용하고 내부 필드(_display_end)는 제거한다
    ce_period = {"Start": period["Start"], "End": period["End"]}
    try:
        ce = session.client("ce", region_name=CE_REGION)
        response = ce.get_cost_and_usage(
            TimePeriod=ce_period, Granularity="DAILY", Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
    except ClientError as e:
        code = e.response["Error"]["Code"]
        log += [f"  [오류] Cost Explorer API 호출 실패: {e}", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": f"CE API 오류 ({code})",
                       "total_usd": None, "billed_services": [], "daily": []})
        return

    # ResultsByTime을 순회해 일별 비용을 집계한다 (범위 조회 시 여러 항목 반환)
    results_by_time = response.get("ResultsByTime", [])
    is_range = len(results_by_time) > 1

    daily = []          # [{"date": ..., "total": ..., "services": [...]}]
    grand_total = 0.0
    service_totals: dict[str, float] = {}  # 기간 전체 서비스별 합계

    for day_result in results_by_time:
        day_date = day_result["TimePeriod"]["Start"]
        day_total = 0.0
        day_services = []
        for group in day_result.get("Groups", []):
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            if round(amount, 4) > 0:
                svc = group["Keys"][0]
                day_services.append({"service": svc, "amount": amount})
                day_total += amount
                service_totals[svc] = service_totals.get(svc, 0) + amount
        daily.append({"date": day_date, "total": day_total, "services": day_services})
        grand_total += day_total

    # 로그 출력 — 범위 조회 시 날짜별로, 단일 날짜 조회 시 서비스별로 표시한다
    if grand_total == 0:
        log.append("  [성공] 해당 기간 발생한 비용 없음 ($0.00)")
    else:
        log.append(f"  [경고] 기간 합계: ${grand_total:.4f} USD")
        if is_range:
            # 날짜별 소계를 보여주고, 각 날짜 아래에 서비스 내역을 나열한다
            for day in daily:
                if day["total"] > 0:
                    log.append(f"  ── {day['date']}  ${day['total']:.4f} USD")
                    for s in sorted(day["services"], key=lambda x: x["amount"], reverse=True):
                        bar = "█" * min(int(s["amount"] / grand_total * 20), 20)
                        log.append(f"    {bar:<20}  ${s['amount']:>10.4f} USD  {s['service']}")
                else:
                    log.append(f"  ── {day['date']}  $0.0000 USD")
        else:
            # 단일 날짜는 기존처럼 서비스별 바 차트로 표시한다
            for svc, amt in sorted(service_totals.items(), key=lambda x: x[1], reverse=True):
                bar = "█" * min(int(amt / grand_total * 20), 20)
                log.append(f"    {bar:<20}  ${amt:>10.4f} USD  {svc}")

    # 기간 전체 서비스별 합계를 billed_services에 저장한다 (요약 출력에 사용)
    billed_services = [
        (svc, amt, "USD")
        for svc, amt in sorted(service_totals.items(), key=lambda x: x[1], reverse=True)
    ]

    log += [f"  [{account_name}] 조회 완료", f"{'='*60}"]
    flush_log(log)
    record_result({"name": account_name, "account_id": account_id,
                   "status": "ok", "total_usd": grand_total,
                   "billed_services": billed_services, "daily": daily})


# ── 요약 출력 ─────────────────────────────────────────────────────────────────

def _print_cost_summary(total_accounts: int, date_label: str) -> None:
    results = get_results()
    ok = [r for r in results if r["status"] == "ok"]
    errors = [r for r in results if r["status"] == "error"]
    with_cost = [r for r in ok if (r["total_usd"] or 0) > 0]

    lines = ["", "=" * 60, "  [최종 통계 요약]", "=" * 60,
             f"  조회 기간        : {date_label}",
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
            for svc, amt, unit in r["billed_services"]:
                lines.append(f"    └ ${amt:.4f} {unit}  {svc}")
    else:
        lines.append("  [확인] 삭제 조치가 필요한 계정 없음")

    lines.append("=" * 60)
    print("\n".join(lines))


# ── CSV 저장 ──────────────────────────────────────────────────────────────────

def _save_csv(results: list[dict], filepath: str, date_label: str) -> None:
    """
    조회 결과를 날짜별 1행 형태의 CSV 파일로 저장한다.

    컬럼 구성: 날짜, 계정1(account_id), 서비스(계정1), 계정2(account_id), 서비스(계정2), ...
    행 구성  : 날짜 하나당 한 행, 각 계정의 합계 비용과 사용 서비스 목록을 가로로 나열한다.
    서비스 셀 형식: "서비스명:$금액 | 서비스명:$금액 | ..." (비용 내림차순 정렬)
    """
    # 조회 성공한 계정만 등록 순서대로 정렬한다
    ok_results = sorted(
        [r for r in results if r["status"] == "ok"],
        key=account_sort_key,
    )
    if not ok_results:
        click.echo("  [정보] 저장할 데이터가 없습니다.")
        return

    # 날짜 목록을 전체 계정에서 수집해 정렬한다
    all_dates: set[str] = set()
    for r in ok_results:
        for day in r.get("daily", []):
            all_dates.add(day["date"])
    if not all_dates:
        click.echo("  [정보] 저장할 데이터가 없습니다.")
        return
    sorted_dates = sorted(all_dates)

    # 계정별로 날짜 → (합계, 서비스 목록) 매핑을 미리 구성한다
    # account_day_data[account_col][날짜] = {"total": float, "services": [(서비스명, 금액), ...]}
    account_day_data: dict[str, dict[str, dict]] = {}
    for r in ok_results:
        col = f"{r['name']}({r['account_id']})"
        account_day_data[col] = {}
        for day in r.get("daily", []):
            services_sorted = sorted(day["services"], key=lambda s: s["amount"], reverse=True)
            account_day_data[col][day["date"]] = {
                "total": day["total"],
                "services": services_sorted,
            }

    # 계정 컬럼 순서 목록 (정렬된 ok_results 기준)
    account_cols = [f"{r['name']}({r['account_id']})" for r in ok_results]

    # 헤더: 날짜, 계정1(id), 서비스(계정1), 계정2(id), 서비스(계정2), ...
    fieldnames = ["날짜"]
    for r in ok_results:
        col = f"{r['name']}({r['account_id']})"
        fieldnames.append(col)                    # 계정 합계 컬럼
        fieldnames.append(f"서비스({r['name']})") # 해당 계정의 사용 서비스 컬럼

    # 계정별 기간 합계를 미리 계산한다 (마지막 합계 행에 사용)
    col_totals = {col: 0.0 for col in account_cols}
    for col in account_cols:
        for day_data in account_day_data[col].values():
            col_totals[col] += day_data["total"]

    with open(filepath, "w", newline="", encoding="utf-8-sig") as f:
        # utf-8-sig: Excel에서 한글이 깨지지 않도록 BOM을 포함한다
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()

        for day_date in sorted_dates:
            row: dict[str, str] = {"날짜": day_date}
            for r in ok_results:
                col = f"{r['name']}({r['account_id']})"
                svc_col = f"서비스({r['name']})"
                day_data = account_day_data[col].get(day_date)
                if day_data and day_data["total"] > 0:
                    # 합계 금액
                    row[col] = f"{day_data['total']:.4f}"
                    # 사용 서비스명만 " | " 구분해 나열한다 (비용 제외)
                    row[svc_col] = " | ".join(s["service"] for s in day_data["services"])
                else:
                    # 해당 날짜에 비용 없음
                    row[col] = "0.0000"
                    row[svc_col] = ""
            writer.writerow(row)

        # 마지막 행에 계정별 기간 합계를 출력한다
        total_row: dict[str, str] = {"날짜": "합계"}
        for r in ok_results:
            col = f"{r['name']}({r['account_id']})"
            svc_col = f"서비스({r['name']})"
            total_row[col] = f"{col_totals[col]:.4f}"
            total_row[svc_col] = ""
        writer.writerow(total_row)

    click.echo(f"  [저장] CSV 파일 저장 완료: {filepath}  ({len(sorted_dates)}행 × {len(account_cols)}개 계정)")


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
              help="단일 날짜 조회 (YYYY-MM-DD, 기본값: 전일)")
@click.option("--from", "date_from", default=None,
              help="범위 조회 시작 날짜 (YYYY-MM-DD)")
@click.option("--to", "date_to", default=None,
              help="범위 조회 종료 날짜 (YYYY-MM-DD, 기본값: 전일)")
@click.option("--save", "save_path", default=None, metavar="FILE.csv",
              help="저장할 CSV 파일명 (기본값: 날짜 범위로 자동 생성)")
def cmd(credentials_file, account_filter, output_fmt, target_date, date_from, date_to, save_path):
    """비용 리포트 (기본값: 지난 2주, 서비스별 · 일별 조회)."""

    # ── 날짜/기간 계산 ─────────────────────────────────────────────────────────
    yesterday = date.today() - timedelta(days=1)
    two_weeks_ago = date.today() - timedelta(days=14)

    if target_date and (date_from or date_to):
        click.echo("오류: --date 와 --from/--to 는 함께 사용할 수 없습니다.", err=True)
        raise SystemExit(1)

    if date_from or date_to:
        # 범위 조회
        try:
            start = datetime.strptime(date_from, "%Y-%m-%d").date() if date_from else two_weeks_ago
            end   = datetime.strptime(date_to,   "%Y-%m-%d").date() if date_to   else yesterday
        except ValueError:
            click.echo("오류: 날짜 형식이 잘못되었습니다. (예: 2026-04-01)", err=True)
            raise SystemExit(1)
        if start > end:
            click.echo("오류: --from 날짜가 --to 날짜보다 늦습니다.", err=True)
            raise SystemExit(1)
        display_end = end
    elif target_date:
        # 단일 날짜
        try:
            start = datetime.strptime(target_date, "%Y-%m-%d").date()
        except ValueError:
            click.echo("오류: --date 형식이 잘못되었습니다. (예: 2026-04-05)", err=True)
            raise SystemExit(1)
        end = start
        display_end = start
    else:
        # 기본값: 지난 2주 (14일 전 ~ 전일)
        start = two_weeks_ago
        end = yesterday
        display_end = yesterday

    # CE API의 End는 조회 마지막 날 + 1일 (exclusive)
    period = {
        "Start": start.strftime("%Y-%m-%d"),
        "End":   (end + timedelta(days=1)).strftime("%Y-%m-%d"),
        "_display_end": display_end.strftime("%Y-%m-%d"),  # 로그 헤더 표시용
    }
    date_label = (period["Start"] if period["Start"] == period["_display_end"]
                  else f"{period['Start']} ~ {period['_display_end']}")
    num_days = (end - start).days + 1

    # ── 계정 로드 + 비용 안내 + 확인 ──────────────────────────────────────────
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    account_count = len(creds)
    api_cost = account_count * 0.01

    click.echo(f"AWS 워크샵 비용 리포트 (조회 기간: {date_label})")
    click.echo(f"")
    click.echo(f"  대상 계정 수  : {account_count}개")
    if num_days > 1:
        click.echo(f"  조회 일수     : {num_days}일 (API 1회 호출로 처리)")
    click.echo(f"  API 호출 비용 : {account_count}개 × $0.01 = ${api_cost:.2f} USD 발생 예정")
    click.echo(f"")
    if not click.confirm("  계속 진행하시겠습니까?", default=False):
        click.echo("취소되었습니다.")
        return
    click.echo("")

    clear_results()
    run_parallel(partial(_check_cost, period=period), creds)

    if output_fmt == "table":
        _print_cost_summary(len(creds), date_label)
    else:
        format_output(get_results(), fmt=output_fmt, title="비용 리포트")

    # 파일명이 지정되지 않으면 날짜 범위로 자동 생성한다 (예: cost-2026-04-01~2026-04-05.csv)
    if not save_path:
        safe_label = date_label.replace(" ", "")
        save_path = f"cost-{safe_label}.csv"
    _save_csv(get_results(), save_path, date_label)

    click.echo("\n모든 계정 조회 완료.")
