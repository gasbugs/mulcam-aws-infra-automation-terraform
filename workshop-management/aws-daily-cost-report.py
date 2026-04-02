# =============================================================================
# aws-daily-cost-report.py
# [용도] 워크샵 수강생 계정의 전일 비용 발생 여부 리포트 스크립트
#
# accesskey.txt 에 등록된 루트 자격증명으로 아래 순서를 실행합니다.
#   1. terraform-user-0 사용자가 없으면 생성
#   2. terraform-user-0 에 Cost Explorer 읽기 권한(인라인 정책) 부여/갱신
#   3. 동일 자격증명으로 전일 비용을 서비스별로 조회 및 출력
#
# 비용이 남아있는 계정은 [경고], 깨끗한 계정은 [성공] 으로 표시됩니다.
#
# [참고] Cost Explorer 데이터는 최대 24시간 지연될 수 있습니다.
#
# [사전 준비] accesskey.txt — 탭으로 구분된 access_key, secret_key (계정당 1줄)
# [실행 방법] python aws-daily-cost-report.py
# =============================================================================
import boto3
import json
import sys
import concurrent.futures
import threading
from botocore.exceptions import ClientError
from datetime import date, timedelta

# Cost Explorer는 전역 서비스 — us-east-1 고정
CE_REGION = "us-east-1"

# 비용 조회 전용 IAM 사용자 및 인라인 정책 이름
COST_REPORTER_USER   = "terraform-user-0"
COST_REPORTER_POLICY = "CostExplorerReadOnly"

# 계정별 출력 블록이 뒤섞이지 않도록 출력 락 사용
_print_lock = threading.Lock()

# 통계용 결과 수집 (thread-safe)
_results: list = []
_results_lock = threading.Lock()


def flush_log(lines: list):
    """버퍼링된 로그를 락을 잡고 한 번에 출력"""
    with _print_lock:
        print("\n".join(lines), flush=True)


def record_result(entry: dict):
    """조회 결과를 통계용 리스트에 추가"""
    with _results_lock:
        _results.append(entry)


def parse_credentials(file_path="accesskey.txt"):
    credentials = []
    try:
        with open(file_path, "r") as f:
            for i, line in enumerate(f):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                try:
                    access_key, secret_key = line.split("\t")
                    credentials.append((access_key.strip(), secret_key.strip(), f"계정 {i + 1}"))
                except ValueError:
                    print(f"경고: {file_path} 파일의 {i + 1}번째 줄 형식이 잘못되었습니다. (탭으로 구분 필요)")
    except FileNotFoundError:
        print(f"오류: '{file_path}' 파일을 찾을 수 없습니다.")
        sys.exit(1)
    return credentials


def get_account_id(session):
    try:
        return session.client("sts").get_caller_identity()["Account"]
    except ClientError:
        return None


def ensure_cost_reporter(iam, log):
    """
    terraform-user-0 사용자가 없으면 생성하고,
    Cost Explorer 읽기 권한 인라인 정책을 항상 최신 상태로 덮어씁니다.
    """
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
        "Statement": [{
            "Sid": "AllowCostExplorerRead",
            "Effect": "Allow",
            "Action": [
                "ce:GetCostAndUsage",
                "ce:GetCostForecast",
                "ce:GetDimensionValues",
                "ce:GetTags",
            ],
            "Resource": "*",
        }]
    })
    try:
        iam.put_user_policy(
            UserName=COST_REPORTER_USER,
            PolicyName=COST_REPORTER_POLICY,
            PolicyDocument=ce_policy,
        )
        log.append(f"  [설정] Cost Explorer 읽기 권한 부여 완료 ({COST_REPORTER_POLICY})")
    except ClientError as e:
        log.append(f"  [오류] 권한 부여 실패: {e}")
        return False

    return True


def verify_ce_permission(session, iam, log):
    """
    iam:SimulatePrincipalPolicy 로 ce:GetCostAndUsage 권한이
    실제로 허용되는지 확인합니다.
    Permission Boundary / SCP 등으로 인라인 정책이 무력화된 경우도 감지합니다.

    반환값:
      True  — 허용 확인 또는 시뮬레이션 자체 권한 없어 확인 불가(시도는 계속)
      False — 명시적/묵시적 거부 확인
    """
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

        # 거부 원인 세부 진단
        reasons = []
        pb = eval_result.get("PermissionsBoundaryDecisionDetail", {})
        if pb and not pb.get("AllowedByPermissionsBoundary", True):
            reasons.append("Permission Boundary 차단")
        org = eval_result.get("OrganizationsDecisionDetail", {})
        if org and not org.get("AllowedByOrganizations", True):
            reasons.append("SCP(Organizations) 차단")
        if not reasons:
            reasons.append("정책 미부여 또는 명시적 Deny")

        log.append(
            f"  [경고] ce:GetCostAndUsage 시뮬레이션 결과: {decision} "
            f"— 원인: {', '.join(reasons)}"
        )
        return False

    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("AccessDenied", "AccessDeniedException"):
            log.append(
                f"  [정보] 권한 시뮬레이션 불가 (iam:SimulatePrincipalPolicy 권한 없음) "
                f"— CE 호출을 직접 시도합니다."
            )
        else:
            log.append(f"  [정보] 권한 시뮬레이션 실패: {e} — CE 호출을 직접 시도합니다.")
        return True  # 확인 불가 시 실제 호출로 검증


def check_yesterday_cost(access_key, secret_key, account_name):
    """루트 자격증명으로 terraform-user-0 권한을 보장한 뒤 전일 비용을 조회하고 결과를 한 번에 출력"""
    yesterday = date.today() - timedelta(days=1)
    period = {
        "Start": yesterday.strftime("%Y-%m-%d"),
        "End":   date.today().strftime("%Y-%m-%d"),
    }

    log = [f"{'='*60}",
           f"  [{account_name} / Key: {access_key[:5]}...] 비용 조회 ({period['Start']})"]

    session = boto3.Session(
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )

    account_id = get_account_id(session)
    if not account_id:
        log.append(f"  [오류] 계정 ID 조회 실패 — 자격증명을 확인하세요.")
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({"account_name": account_name, "account_id": None,
                       "status": "error", "error_reason": "자격증명 오류",
                       "total_usd": None, "billed_services": []})
        return

    log.append(f"  계정 ID: {account_id}")

    # terraform-user-0 생성 및 CE 권한 보장
    iam = session.client("iam")
    if not ensure_cost_reporter(iam, log):
        log.append(f"  [{account_name}] 조회 중단 (권한 설정 실패)")
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({"account_name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": "IAM 권한 설정 실패",
                       "total_usd": None, "billed_services": []})
        return

    # ce:GetCostAndUsage 권한이 실제로 유효한지 시뮬레이션으로 검증
    if not verify_ce_permission(session, iam, log):
        log.append(f"  [{account_name}] 조회 중단 (ce:GetCostAndUsage 권한 부족)")
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({"account_name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": "CE 권한 부족 (SCP/Boundary)",
                       "total_usd": None, "billed_services": []})
        return

    try:
        ce = session.client("ce", region_name=CE_REGION)
        response = ce.get_cost_and_usage(
            TimePeriod=period,
            Granularity="DAILY",
            Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("AccessDeniedException", "AuthFailure"):
            log.append(f"  [오류] Cost Explorer 접근 권한이 없습니다. (ce:GetCostAndUsage 권한 필요)")
            reason = "CE API 접근 거부"
        else:
            log.append(f"  [오류] Cost Explorer API 호출 실패: {e}")
            reason = f"CE API 오류 ({code})"
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({"account_name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": reason,
                       "total_usd": None, "billed_services": []})
        return

    results = response.get("ResultsByTime", [])
    if not results:
        log.append(f"  [정보] 조회 결과 없음")
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({"account_name": account_name, "account_id": account_id,
                       "status": "no_data", "total_usd": None, "billed_services": []})
        return

    groups = results[0].get("Groups", [])
    total_usd = 0.0
    billed_services = []

    for group in groups:
        service_name = group["Keys"][0]
        amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
        unit   = group["Metrics"]["UnblendedCost"]["Unit"]
        if round(amount, 4) > 0:
            billed_services.append((service_name, amount, unit))
            total_usd += amount

    if not billed_services:
        log.append(f"  [성공] 어제 발생한 비용 없음 ($0.00)")
    else:
        log.append(f"  [경고] 비용 발생 — 합계: ${total_usd:.4f} USD")
        for svc, amt, unit in sorted(billed_services, key=lambda x: x[1], reverse=True):
            bar = "█" * min(int(amt / total_usd * 20), 20)
            log.append(f"    {bar:<20}  ${amt:>10.4f} {unit}  {svc}")

    log.append(f"  [{account_name}] 조회 완료")
    log.append(f"{'='*60}")
    flush_log(log)
    record_result({"account_name": account_name, "account_id": account_id,
                   "status": "ok", "total_usd": total_usd, "billed_services": billed_services})


# ── 통계 출력 ─────────────────────────────────────────────────────────────────

def _account_sort_key(entry: dict) -> int:
    """'계정 3' 같은 이름에서 번호를 추출해 정렬에 사용"""
    try:
        return int(entry["account_name"].split()[-1])
    except (ValueError, IndexError):
        return 0


def print_summary(total_accounts: int):
    """전체 조회 결과를 요약해 출력합니다."""
    ok      = [r for r in _results if r["status"] == "ok"]
    errors  = [r for r in _results if r["status"] == "error"]
    no_data = [r for r in _results if r["status"] == "no_data"]

    zero_cost  = [r for r in ok if r["total_usd"] == 0.0]
    with_cost  = [r for r in ok if r["total_usd"] > 0.0]
    queried    = len(ok) + len(no_data)   # CE 응답을 받은 계정 수

    lines = [
        "",
        "=" * 60,
        "  [최종 통계 요약]",
        "=" * 60,
        f"  전체 계정 수        : {total_accounts}개",
        f"  조회 성공           : {len(ok)}개",
        f"  조회 실패 / 오류    : {len(errors)}개",
        f"  데이터 없음         : {len(no_data)}개",
    ]

    if queried > 0:
        zero_pct = len(zero_cost) / queried * 100
        cost_pct = len(with_cost) / queried * 100
        lines += [
            f"  ─────────────────────────────────────",
            f"  $0 (정상)           : {len(zero_cost)}개 / {queried}개  ({zero_pct:.1f}%)",
            f"  비용 발생 (주의)     : {len(with_cost)}개 / {queried}개  ({cost_pct:.1f}%)",
        ]

    if ok:
        total_sum = sum(r["total_usd"] for r in ok)
        lines.append(f"  전체 비용 합계      : ${total_sum:.4f} USD")

    # 오류 종류별 통계
    if errors:
        from collections import Counter
        reason_counter = Counter(r.get("error_reason", "알 수 없음") for r in errors)
        lines += [
            f"  ─────────────────────────────────────",
            f"  오류 종류별 현황:",
        ]
        for reason, count in sorted(reason_counter.items(), key=lambda x: -x[1]):
            lines.append(f"    · {reason:<30} {count}개")
            for r in sorted(
                [e for e in errors if e.get("error_reason") == reason],
                key=_account_sort_key,
            ):
                aid = r["account_id"] or "ID 미확인"
                lines.append(f"        {r['account_name']}  ({aid})")

    # 삭제 조치 필요 계정 — 계정 번호 오름차순
    if with_cost:
        lines += [
            "",
            "=" * 60,
            "  [삭제 조치 필요 계정]  (비용 발생 · 계정 번호 순)",
            "=" * 60,
        ]
        for r in sorted(with_cost, key=_account_sort_key):
            aid = r["account_id"] or "알 수 없음"
            lines.append(f"  {r['account_name']:<10}  계정 ID: {aid}  합계: ${r['total_usd']:.4f} USD")
            for svc, amt, unit in sorted(r["billed_services"], key=lambda x: x[1], reverse=True):
                lines.append(f"    └ ${amt:.4f} {unit}  {svc}")
    else:
        lines += ["", "  [확인] 삭제 조치가 필요한 계정 없음"]

    lines.append("=" * 60)
    print("\n".join(lines))


# ── 진입점 ────────────────────────────────────────────────────────────────────

def main():
    yesterday = (date.today() - timedelta(days=1)).strftime("%Y-%m-%d")
    print(f"AWS 워크샵 전일 비용 리포트 시작 (조회 날짜: {yesterday})\n")

    creds = parse_credentials()
    if not creds:
        print("처리할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    print(f"총 {len(creds)}개의 계정을 조회합니다.")

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = {
            executor.submit(check_yesterday_cost, ak, sk, name): name
            for ak, sk, name in creds
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()
            except Exception as e:
                with _print_lock:
                    print(f"[오류] {futures[future]} 처리 중 예외 발생: {e}", flush=True)

    print_summary(len(creds))
    print("\n모든 계정 조회 완료.")


if __name__ == "__main__":
    main()
