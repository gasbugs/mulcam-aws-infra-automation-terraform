# =============================================================================
# aws-limit-check.py
# [용도] 워크샵 수강생 계정의 서비스 한도 제한 여부 확인 스크립트
#
# accesskey.txt 에 등록된 자격증명으로 아래 두 가지를 확인합니다.
#   1. CloudFront — 계정 미인증으로 인한 리소스 생성 차단 여부
#   2. ALB (us-east-1) — 로드밸런서 생성 지원 여부
#
# 확인 방법: 최소 설정으로 실제 생성을 시도하고 오류 메시지로 판별합니다.
#   - 한도 오류    → [제한] 표시
#   - 생성 성공    → 즉시 삭제 후 [정상] 표시
#   - 기타 오류    → [확인불가] 표시 (권한 부족 등)
#
# [사전 준비] accesskey.txt — 탭으로 구분된 access_key, secret_key (계정당 1줄)
# [실행 방법] python aws-limit-check.py
# =============================================================================
import boto3
import sys
import uuid
import concurrent.futures
import threading
from botocore.exceptions import ClientError
from collections import Counter

REGION = "us-east-1"

_print_lock   = threading.Lock()
_results: list = []
_results_lock = threading.Lock()

# 제한 오류 메시지 키워드 (부분 일치)
CF_LIMIT_KEYWORDS  = ["account must be verified", "contact aws support"]
ALB_LIMIT_KEYWORDS = ["does not support creating load balancers"]


def flush_log(lines: list):
    with _print_lock:
        print("\n".join(lines), flush=True)


def record_result(entry: dict):
    with _results_lock:
        _results.append(entry)


def _account_sort_key(entry: dict) -> int:
    try:
        return int(entry["account_name"].split()[-1])
    except (ValueError, IndexError):
        return 0


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
                    print(f"경고: {i + 1}번째 줄 형식 오류 (탭 구분 필요)")
    except FileNotFoundError:
        print(f"오류: 'accesskey.txt' 파일을 찾을 수 없습니다.")
        sys.exit(1)
    return credentials


def get_account_id(session):
    try:
        return session.client("sts").get_caller_identity()["Account"]
    except ClientError:
        return None


def _is_limit_error(message: str, keywords: list) -> bool:
    msg_lower = message.lower()
    return any(kw.lower() in msg_lower for kw in keywords)


# ── CloudFront 한도 확인 ───────────────────────────────────────────────────────

def check_cloudfront(session, log) -> str:
    """
    최소 설정으로 CloudFront 배포 생성을 시도합니다.
    반환값: "ok" | "limited" | "unknown"
    """
    cf = session.client("cloudfront")
    caller_ref = f"limit-check-{uuid.uuid4().hex[:8]}"
    dist_id = None
    try:
        resp = cf.create_distribution(
            DistributionConfig={
                "CallerReference": caller_ref,
                "Comment": "limit-check (auto-delete)",
                "Enabled": False,
                "Origins": {
                    "Quantity": 1,
                    "Items": [{
                        "Id": "origin-1",
                        "DomainName": "example.com",
                        "CustomOriginConfig": {
                            "HTTPPort": 80,
                            "HTTPSPort": 443,
                            "OriginProtocolPolicy": "https-only",
                        },
                    }],
                },
                "DefaultCacheBehavior": {
                    "TargetOriginId": "origin-1",
                    "ViewerProtocolPolicy": "redirect-to-https",
                    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",  # CachingOptimized (AWS managed)
                    "AllowedMethods": {
                        "Quantity": 2,
                        "Items": ["GET", "HEAD"],
                    },
                },
            }
        )
        dist_id = resp["Distribution"]["Id"]
        etag    = resp["ETag"]
        log.append(f"  [CloudFront] 생성 성공 — 즉시 삭제 중 (ID: {dist_id})")
        # 생성 성공 시 즉시 비활성화 후 삭제
        try:
            cfg = cf.get_distribution_config(Id=dist_id)
            cfg["DistributionConfig"]["Enabled"] = False
            cf.update_distribution(
                Id=dist_id,
                DistributionConfig=cfg["DistributionConfig"],
                IfMatch=cfg["ETag"],
            )
        except ClientError:
            pass  # 비활성화 실패해도 삭제 시도
        try:
            latest_etag = cf.get_distribution(Id=dist_id)["ETag"]
            cf.delete_distribution(Id=dist_id, IfMatch=latest_etag)
            log.append(f"  [CloudFront] 삭제 완료")
        except ClientError as del_e:
            log.append(f"  [CloudFront] 삭제 실패 (수동 삭제 필요): {del_e}")
        return "ok"

    except ClientError as e:
        msg  = e.response["Error"].get("Message", "")
        code = e.response["Error"].get("Code", "")
        if _is_limit_error(msg, CF_LIMIT_KEYWORDS):
            log.append(f"  [CloudFront] 제한 감지: {msg}")
            return "limited"
        # 설정 오류(MalformedInput 등)는 계정 제한이 아니므로 정상으로 처리
        if code in ("MalformedInput", "InvalidArgument", "NoSuchCachePolicy"):
            log.append(f"  [CloudFront] 설정 오류 — 계정 제한 없음 ({code})")
            return "ok"
        log.append(f"  [CloudFront] 확인 불가 ({code}): {msg}")
        return "unknown"


# ── ALB 한도 확인 ─────────────────────────────────────────────────────────────

def get_default_vpc_subnets(session, log):
    """기본 VPC에서 서로 다른 AZ의 서브넷 2개를 반환합니다."""
    ec2 = session.client("ec2", region_name=REGION)
    try:
        vpcs = ec2.describe_vpcs(
            Filters=[{"Name": "isDefault", "Values": ["true"]}]
        )["Vpcs"]
        if not vpcs:
            log.append(f"  [ALB] 기본 VPC 없음 — 서브넷 조회 불가")
            return []
        vpc_id = vpcs[0]["VpcId"]
        subnets = ec2.describe_subnets(
            Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
        )["Subnets"]
        # AZ별 1개씩, 최소 2개
        seen_az: dict = {}
        for s in subnets:
            az = s["AvailabilityZone"]
            if az not in seen_az:
                seen_az[az] = s["SubnetId"]
            if len(seen_az) >= 2:
                break
        if len(seen_az) < 2:
            log.append(f"  [ALB] AZ가 2개 미만 — 서브넷 부족")
            return []
        return list(seen_az.values())
    except ClientError as e:
        log.append(f"  [ALB] 서브넷 조회 실패: {e}")
        return []


def check_alb(session, log) -> str:
    """
    기본 VPC 서브넷에 최소 설정으로 ALB 생성을 시도합니다.
    반환값: "ok" | "limited" | "unknown"
    """
    subnet_ids = get_default_vpc_subnets(session, log)
    if not subnet_ids:
        return "unknown"

    elb  = session.client("elbv2", region_name=REGION)
    name = f"lc-{uuid.uuid4().hex[:8]}"
    try:
        resp = elb.create_load_balancer(
            Name=name,
            Subnets=subnet_ids,
            Type="application",
            Scheme="internet-facing",
        )
        lb_arn = resp["LoadBalancers"][0]["LoadBalancerArn"]
        log.append(f"  [ALB] 생성 성공 — 즉시 삭제 중")
        try:
            elb.delete_load_balancer(LoadBalancerArn=lb_arn)
            log.append(f"  [ALB] 삭제 완료")
        except ClientError as del_e:
            log.append(f"  [ALB] 삭제 실패 (수동 삭제 필요): {del_e}")
        return "ok"

    except ClientError as e:
        msg  = e.response["Error"].get("Message", "")
        code = e.response["Error"].get("Code", "")
        if _is_limit_error(msg, ALB_LIMIT_KEYWORDS):
            log.append(f"  [ALB] 제한 감지: {msg}")
            return "limited"
        log.append(f"  [ALB] 확인 불가 ({code}): {msg}")
        return "unknown"


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def check_account(access_key, secret_key, account_name):
    log = [
        f"{'='*60}",
        f"  [{account_name} / Key: {access_key[:5]}...] 한도 확인 시작",
    ]

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
                       "cf": "error", "alb": "error"})
        return

    log.append(f"  계정 ID: {account_id}")

    cf_result  = check_cloudfront(session, log)
    alb_result = check_alb(session, log)

    cf_label  = {"ok": "[정상]", "limited": "[제한]", "unknown": "[확인불가]"}.get(cf_result, cf_result)
    alb_label = {"ok": "[정상]", "limited": "[제한]", "unknown": "[확인불가]"}.get(alb_result, alb_result)
    log.append(f"  결과 → CloudFront: {cf_label}  /  ALB: {alb_label}")
    log.append(f"{'='*60}")
    flush_log(log)
    record_result({"account_name": account_name, "account_id": account_id,
                   "cf": cf_result, "alb": alb_result})


# ── 통계 출력 ─────────────────────────────────────────────────────────────────

def print_summary(total: int):
    cf_counter  = Counter(r["cf"]  for r in _results)
    alb_counter = Counter(r["alb"] for r in _results)

    label = {"ok": "정상", "limited": "제한", "unknown": "확인불가", "error": "오류"}

    lines = [
        "",
        "=" * 60,
        "  [최종 통계 요약]",
        "=" * 60,
        f"  전체 계정 수 : {total}개",
        f"  ─────────────────────────────────────",
        f"  CloudFront",
    ]
    for status in ("ok", "limited", "unknown", "error"):
        cnt = cf_counter.get(status, 0)
        if cnt:
            lines.append(f"    · {label[status]:<8} : {cnt}개")

    lines += [f"  ─────────────────────────────────────", f"  ALB (us-east-1)"]
    for status in ("ok", "limited", "unknown", "error"):
        cnt = alb_counter.get(status, 0)
        if cnt:
            lines.append(f"    · {label[status]:<8} : {cnt}개")

    # 제한 걸린 계정 목록 — 계정 번호 오름차순
    limited = sorted(
        [r for r in _results if r["cf"] == "limited" or r["alb"] == "limited"],
        key=_account_sort_key,
    )
    if limited:
        lines += [
            "",
            "=" * 60,
            "  [제한 발생 계정 목록]  (AWS Support 문의 필요 · 계정 번호 순)",
            "=" * 60,
        ]
        for r in limited:
            aid      = r["account_id"] or "ID 미확인"
            cf_lbl   = "제한" if r["cf"]  == "limited" else "-"
            alb_lbl  = "제한" if r["alb"] == "limited" else "-"
            lines.append(
                f"  {r['account_name']:<10}  계정 ID: {aid}"
                f"  CloudFront: {cf_lbl:4}  ALB: {alb_lbl}"
            )
    else:
        lines += ["", "  [확인] 제한 발생 계정 없음"]

    lines.append("=" * 60)
    print("\n".join(lines))


# ── 진입점 ────────────────────────────────────────────────────────────────────

def main():
    print("AWS 서비스 한도 확인 스크립트 시작")
    print(f"  확인 항목: CloudFront 계정 인증, ALB 생성 지원 ({REGION})\n")

    creds = parse_credentials()
    if not creds:
        print("처리할 계정 정보가 없습니다.")
        return

    print(f"총 {len(creds)}개의 계정을 확인합니다.")

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = {
            executor.submit(check_account, ak, sk, name): name
            for ak, sk, name in creds
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()
            except Exception as e:
                with _print_lock:
                    print(f"[오류] {futures[future]} 처리 중 예외 발생: {e}", flush=True)

    print_summary(len(creds))
    print("\n모든 계정 확인 완료.")


if __name__ == "__main__":
    main()
