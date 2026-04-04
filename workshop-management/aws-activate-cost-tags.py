# =============================================================================
# aws-activate-cost-tags.py
# [용도] 비용 태그(Cost Allocation Tags) 활성화 스크립트
#
# accesskey.txt 에 등록된 루트 자격증명으로 아래 순서를 실행합니다.
#   1. 현재 태그 활성화 상태 조회
#   2. 미등록 태그가 있으면 임시 VPC를 생성해 모든 태그를 리소스에 부착
#      → Cost Explorer가 태그를 인식하도록 등록 (VPC는 생성 후 즉시 삭제)
#   3. 비활성(Inactive) 태그를 Active로 활성화
#
# [참고] Cost Explorer 태그 데이터는 활성화 후 최대 24시간 후에 검색 가능합니다.
#        수업 전날 이 스크립트를 실행해 두세요.
#
# [활성화 대상 태그]
#   Project, CostCenter, Environment, Owner, Name
#
# [사전 준비] accesskey.txt — 탭으로 구분된 access_key, secret_key (계정당 1줄)
# [실행 방법] python aws-activate-cost-tags.py
# =============================================================================
import boto3
import sys
import time
import concurrent.futures
import threading
from botocore.exceptions import ClientError

# Cost Explorer는 전역 서비스 — us-east-1 고정
CE_REGION = "us-east-1"

# 임시 VPC를 생성할 리전 (워크샵 기본 리전과 동일)
VPC_REGION = "us-east-1"

# 활성화할 태그 목록
TARGET_TAGS = ["Project", "CostCenter", "Environment", "Owner", "Name"]

# 임시 VPC에 붙일 태그 값 (태그 키를 Cost Explorer에 등록하기 위한 더미 값)
DUMMY_TAG_VALUES = {
    "Project":     "workshop",
    "CostCenter":  "workshop",
    "Environment": "workshop",
    "Owner":       "workshop",
    "Name":        "tag-registration-temp-vpc",
}

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
    """처리 결과를 통계용 리스트에 추가"""
    with _results_lock:
        _results.append(entry)


def parse_credentials(file_path="accesskey.txt"):
    """accesskey.txt에서 자격증명 파싱 (탭 구분, 계정당 1줄)"""
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
    """STS를 통해 현재 자격증명의 AWS 계정 ID 조회"""
    try:
        return session.client("sts").get_caller_identity()["Account"]
    except ClientError:
        return None


def create_temp_vpc_with_tags(session, log):
    """
    모든 대상 태그를 부착한 임시 VPC를 생성하고 즉시 삭제한다.
    Cost Explorer는 리소스에 태그가 한 번이라도 붙어 있어야 태그 키를 인식하므로,
    이 과정을 통해 미등록 태그를 Cost Explorer에 등록시킨다.
    VPC는 생성 후 즉시 삭제하여 불필요한 비용이 발생하지 않도록 한다.
    """
    ec2 = session.client("ec2", region_name=VPC_REGION)

    # 임시 VPC 생성 (CIDR은 비용 없음, VPC 자체도 무료)
    log.append(f"  [VPC] 임시 VPC 생성 중 (태그 등록 목적)...")
    try:
        vpc = ec2.create_vpc(CidrBlock="10.99.0.0/16")
        vpc_id = vpc["Vpc"]["VpcId"]
    except ClientError as e:
        log.append(f"  [오류] VPC 생성 실패: {e.response['Error']['Code']} — {e.response['Error']['Message']}")
        return False

    log.append(f"  [VPC] 생성 완료: {vpc_id}")

    # 모든 대상 태그를 VPC에 부착 — 이 시점에 Cost Explorer가 태그 키를 인식하기 시작
    tags = [{"Key": k, "Value": v} for k, v in DUMMY_TAG_VALUES.items()]
    try:
        ec2.create_tags(Resources=[vpc_id], Tags=tags)
        log.append(f"  [VPC] 태그 부착 완료: {', '.join(DUMMY_TAG_VALUES.keys())}")
    except ClientError as e:
        log.append(f"  [경고] VPC 태그 부착 실패: {e.response['Error']['Message']} — VPC 삭제 진행")

    # VPC 즉시 삭제 — 비용 발생 방지
    try:
        ec2.delete_vpc(VpcId=vpc_id)
        log.append(f"  [VPC] 임시 VPC 삭제 완료: {vpc_id}")
    except ClientError as e:
        log.append(f"  [경고] VPC 삭제 실패 (수동 삭제 필요): {vpc_id} — {e.response['Error']['Message']}")

    return True


def get_tag_status(ce, log):
    """Cost Explorer에서 대상 태그의 현재 활성화 상태를 조회한다."""
    try:
        response = ce.list_cost_allocation_tags(
            TagKeys=TARGET_TAGS,
            MaxResults=100,
        )
        return {t["TagKey"]: t["Status"] for t in response.get("CostAllocationTags", [])}
    except ClientError as e:
        code = e.response["Error"]["Code"]
        log.append(f"  [오류] 태그 상태 조회 실패: {code} — {e.response['Error']['Message']}")
        return None


def activate_cost_tags(access_key, secret_key, account_name):
    """
    루트 자격증명으로 비용 할당 태그를 조회하고,
    미등록 태그는 임시 VPC로 등록한 뒤 모두 활성화한다.
    """
    log = [
        f"{'='*60}",
        f"  [{account_name} / Key: {access_key[:5]}...] 태그 활성화 처리",
    ]

    # boto3 세션 생성 (루트 자격증명 사용)
    session = boto3.Session(
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )

    # 계정 ID 확인
    account_id = get_account_id(session)
    if not account_id:
        log.append(f"  [오류] 계정 ID 조회 실패 — 자격증명을 확인하세요.")
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({
            "account_name": account_name,
            "account_id": None,
            "status": "error",
            "error_reason": "자격증명 오류",
        })
        return

    log.append(f"  계정 ID: {account_id}")

    ce = session.client("ce", region_name=CE_REGION)

    # ── 1단계: 현재 태그 활성화 상태 조회 ─────────────────────────────────────
    existing_tags = get_tag_status(ce, log)
    if existing_tags is None:
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({
            "account_name": account_name,
            "account_id": account_id,
            "status": "error",
            "error_reason": "태그 상태 조회 실패",
        })
        return

    # 현재 상태 출력
    log.append(f"  현재 태그 상태:")
    for tag in TARGET_TAGS:
        status = existing_tags.get(tag)
        if status == "Active":
            mark = "[활성]  "
        elif status == "Inactive":
            mark = "[비활성]"
        else:
            mark = "[미등록]"  # 리소스에 한 번도 사용된 적 없는 태그
        log.append(f"    {mark} {tag}")

    # ── 2단계: 미등록 태그가 있으면 임시 VPC로 태그 등록 ─────────────────────
    unregistered = [tag for tag in TARGET_TAGS if tag not in existing_tags]
    if unregistered:
        log.append(f"  [안내] 미등록 태그 발견: {', '.join(unregistered)}")
        log.append(f"  [안내] 임시 VPC를 생성해 태그를 Cost Explorer에 등록합니다.")

        ok = create_temp_vpc_with_tags(session, log)
        if not ok:
            log.append(f"  [오류] 태그 등록용 VPC 생성 실패 — 처리 중단")
            log.append(f"{'='*60}")
            flush_log(log)
            record_result({
                "account_name": account_name,
                "account_id": account_id,
                "status": "error",
                "error_reason": "임시 VPC 생성 실패",
            })
            return

        # Cost Explorer가 새 태그를 인식하는 데 수 초 소요될 수 있어 잠시 대기
        log.append(f"  [대기] Cost Explorer 태그 인식 대기 중 (10초)...")
        time.sleep(10)

        # 태그 상태 재조회
        existing_tags = get_tag_status(ce, log)
        if existing_tags is None:
            log.append(f"{'='*60}")
            flush_log(log)
            record_result({
                "account_name": account_name,
                "account_id": account_id,
                "status": "error",
                "error_reason": "태그 상태 재조회 실패",
            })
            return

        log.append(f"  재조회 후 태그 상태:")
        for tag in TARGET_TAGS:
            status = existing_tags.get(tag)
            mark = "[활성]  " if status == "Active" else ("[비활성]" if status == "Inactive" else "[미등록]")
            log.append(f"    {mark} {tag}")

    # ── 3단계: Inactive 태그 활성화 ───────────────────────────────────────────
    # Active가 아닌 태그만 활성화 요청 (미등록은 VPC 생성 후 Inactive로 바뀌어 있어야 함)
    tags_to_activate = [
        tag for tag in TARGET_TAGS
        if existing_tags.get(tag) == "Inactive"
    ]

    if not tags_to_activate:
        # 모두 이미 Active이거나, VPC 생성 후에도 여전히 미등록 상태
        still_unregistered = [tag for tag in TARGET_TAGS if tag not in existing_tags]
        if still_unregistered:
            log.append(f"  [경고] VPC 생성 후에도 미등록 상태인 태그: {', '.join(still_unregistered)}")
            log.append(f"  [참고] Cost Explorer 태그 반영에 최대 24시간 소요될 수 있습니다.")
            log.append(f"{'='*60}")
            flush_log(log)
            record_result({
                "account_name": account_name,
                "account_id": account_id,
                "status": "pending",
                "pending_tags": still_unregistered,
            })
        else:
            log.append(f"  [성공] 모든 태그가 이미 활성화되어 있습니다.")
            log.append(f"{'='*60}")
            flush_log(log)
            record_result({
                "account_name": account_name,
                "account_id": account_id,
                "status": "already_active",
            })
        return

    log.append(f"  활성화 요청 태그: {', '.join(tags_to_activate)}")

    try:
        ce.update_cost_allocation_tags_status(
            CostAllocationTagsStatus=[
                {"TagKey": tag, "Status": "Active"}
                for tag in tags_to_activate
            ]
        )
        log.append(f"  [성공] {len(tags_to_activate)}개 태그 활성화 완료")
        log.append(f"  [참고] 태그 데이터는 활성화 후 최대 24시간 후에 검색 가능합니다.")
    except ClientError as e:
        code = e.response["Error"]["Code"]
        log.append(f"  [오류] 태그 활성화 실패: {code} — {e.response['Error']['Message']}")
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({
            "account_name": account_name,
            "account_id": account_id,
            "status": "error",
            "error_reason": f"태그 활성화 실패 ({code})",
        })
        return

    log.append(f"{'='*60}")
    flush_log(log)
    record_result({
        "account_name": account_name,
        "account_id": account_id,
        "status": "activated",
        "activated_tags": tags_to_activate,
    })


# ── 통계 출력 ─────────────────────────────────────────────────────────────────

def print_summary(total_accounts: int):
    """전체 처리 결과를 요약해 출력"""
    activated  = [r for r in _results if r["status"] == "activated"]
    already_ok = [r for r in _results if r["status"] == "already_active"]
    pending    = [r for r in _results if r["status"] == "pending"]
    errors     = [r for r in _results if r["status"] == "error"]

    lines = [
        "",
        "=" * 60,
        "  [최종 통계 요약]",
        "=" * 60,
        f"  전체 계정 수            : {total_accounts}개",
        f"  태그 활성화 완료        : {len(activated)}개",
        f"  이미 전체 활성화        : {len(already_ok)}개",
        f"  반영 대기 중 (24h)      : {len(pending)}개",
        f"  처리 실패               : {len(errors)}개",
    ]

    if pending:
        lines += [
            f"  ─────────────────────────────────────",
            f"  반영 대기 계정 (VPC 생성 완료, CE 반영 24h 소요):",
        ]
        for r in pending:
            lines.append(f"    · {r['account_name']}  ({r['account_id']})  미등록: {', '.join(r.get('pending_tags', []))}")

    if errors:
        from collections import Counter
        reason_counter = Counter(r.get("error_reason", "알 수 없음") for r in errors)
        lines += [
            f"  ─────────────────────────────────────",
            f"  오류 종류별 현황:",
        ]
        for reason, count in sorted(reason_counter.items(), key=lambda x: -x[1]):
            lines.append(f"    · {reason:<35} {count}개")

    lines += [
        "=" * 60,
        "  [참고] 태그 데이터 검색은 활성화 후 최대 24시간이 소요됩니다.",
        "=" * 60,
    ]
    print("\n".join(lines))


# ── 진입점 ────────────────────────────────────────────────────────────────────

def main():
    print("AWS 비용 할당 태그 활성화 스크립트 시작\n")
    print(f"활성화 대상 태그: {', '.join(TARGET_TAGS)}\n")

    creds = parse_credentials()
    if not creds:
        print("처리할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    print(f"총 {len(creds)}개의 계정을 처리합니다.\n")

    # 병렬로 각 계정의 태그 활성화 처리
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = {
            executor.submit(activate_cost_tags, ak, sk, name): name
            for ak, sk, name in creds
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()
            except Exception as e:
                with _print_lock:
                    print(f"[오류] {futures[future]} 처리 중 예외 발생: {e}", flush=True)

    print_summary(len(creds))
    print("\n모든 계정 처리 완료.")


if __name__ == "__main__":
    main()
