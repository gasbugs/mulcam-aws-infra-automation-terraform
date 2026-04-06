# =============================================================================
# commands/tag.py
# awsw tag — Cost Allocation 태그 활성화
#
# 기존 aws-activate-cost-tags.py 의 로직을 click 커맨드로 래핑한다.
# =============================================================================
from __future__ import annotations

import time
from functools import partial

import click
from botocore.exceptions import ClientError

from utils.credentials import filter_credentials, load_credentials
from utils.output import flush_log, record_result, clear_results, get_results, set_current_account
from utils.parallel import run_parallel
from utils.session import get_account_id, make_session

CE_REGION  = "us-east-1"
VPC_REGION = "us-east-1"
TARGET_TAGS = ["Project", "CostCenter", "Environment", "Owner", "Name"]
DUMMY_TAG_VALUES = {
    "Project": "workshop", "CostCenter": "workshop",
    "Environment": "workshop", "Owner": "workshop",
    "Name": "tag-registration-temp-vpc",
}


# ── 헬퍼 ──────────────────────────────────────────────────────────────────────

def _create_temp_vpc_with_tags(session, log: list) -> bool:
    """임시 VPC를 생성해 태그를 Cost Explorer에 등록한 뒤 즉시 삭제한다."""
    ec2 = session.client("ec2", region_name=VPC_REGION)
    log.append("  [VPC] 임시 VPC 생성 중 (태그 등록 목적)...")
    try:
        vpc_id = ec2.create_vpc(CidrBlock="10.99.0.0/16")["Vpc"]["VpcId"]
    except ClientError as e:
        log.append(f"  [오류] VPC 생성 실패: {e.response['Error']['Code']} — {e.response['Error']['Message']}")
        return False

    log.append(f"  [VPC] 생성 완료: {vpc_id}")
    try:
        ec2.create_tags(Resources=[vpc_id],
                        Tags=[{"Key": k, "Value": v} for k, v in DUMMY_TAG_VALUES.items()])
        log.append(f"  [VPC] 태그 부착 완료: {', '.join(DUMMY_TAG_VALUES.keys())}")
    except ClientError as e:
        log.append(f"  [경고] VPC 태그 부착 실패: {e.response['Error']['Message']}")

    try:
        ec2.delete_vpc(VpcId=vpc_id)
        log.append(f"  [VPC] 임시 VPC 삭제 완료: {vpc_id}")
    except ClientError as e:
        log.append(f"  [경고] VPC 삭제 실패 (수동 삭제 필요): {vpc_id} — {e.response['Error']['Message']}")
    return True


def _get_tag_status(ce, log: list) -> dict | None:
    """Cost Explorer에서 대상 태그의 현재 활성화 상태를 조회한다."""
    try:
        resp = ce.list_cost_allocation_tags(TagKeys=TARGET_TAGS, MaxResults=100)
        return {t["TagKey"]: t["Status"] for t in resp.get("CostAllocationTags", [])}
    except ClientError as e:
        log.append(f"  [오류] 태그 상태 조회 실패: {e.response['Error']['Code']}")
        return None


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def _activate_tags(cred: dict) -> None:
    set_current_account(cred["name"])  # 지연 출력 모드에서 계정 로그 버퍼 연결
    account_name = cred["name"]
    log = [f"{'='*60}", f"  [{account_name} / Key: {cred['access_key'][:5]}...] 태그 활성화 처리"]

    session = make_session(cred["access_key"], cred["secret_key"])
    account_id = get_account_id(session)
    if not account_id:
        log += ["  [오류] 계정 ID 조회 실패", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": None, "status": "error", "error_reason": "자격증명 오류"})
        return

    log.append(f"  계정 ID: {account_id}")
    ce = session.client("ce", region_name=CE_REGION)

    existing_tags = _get_tag_status(ce, log)
    if existing_tags is None:
        log.append(f"{'='*60}")
        flush_log(log)
        record_result({"name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": "태그 상태 조회 실패"})
        return

    log.append("  현재 태그 상태:")
    for tag in TARGET_TAGS:
        status = existing_tags.get(tag)
        mark = "[활성]  " if status == "Active" else ("[비활성]" if status == "Inactive" else "[미등록]")
        log.append(f"    {mark} {tag}")

    # 미등록 태그가 있으면 임시 VPC로 등록
    unregistered = [t for t in TARGET_TAGS if t not in existing_tags]
    if unregistered:
        log.append(f"  [안내] 미등록 태그 발견: {', '.join(unregistered)} — 임시 VPC로 등록")
        if not _create_temp_vpc_with_tags(session, log):
            log.append(f"{'='*60}")
            flush_log(log)
            record_result({"name": account_name, "account_id": account_id,
                           "status": "error", "error_reason": "임시 VPC 생성 실패"})
            return

        log.append("  [대기] Cost Explorer 태그 인식 대기 중 (10초)...")
        time.sleep(10)
        existing_tags = _get_tag_status(ce, log)
        if existing_tags is None:
            log.append(f"{'='*60}")
            flush_log(log)
            record_result({"name": account_name, "account_id": account_id,
                           "status": "error", "error_reason": "태그 상태 재조회 실패"})
            return

    # Inactive 태그 활성화
    to_activate = [t for t in TARGET_TAGS if existing_tags.get(t) == "Inactive"]
    if not to_activate:
        still_unregistered = [t for t in TARGET_TAGS if t not in existing_tags]
        if still_unregistered:
            log.append(f"  [경고] VPC 생성 후에도 미등록 상태인 태그: {', '.join(still_unregistered)}")
            log.append("  [참고] Cost Explorer 태그 반영에 최대 24시간 소요될 수 있습니다.")
            log.append(f"{'='*60}")
            flush_log(log)
            record_result({"name": account_name, "account_id": account_id,
                           "status": "pending", "pending_tags": still_unregistered})
        else:
            log += ["  [성공] 모든 태그가 이미 활성화되어 있습니다.", f"{'='*60}"]
            flush_log(log)
            record_result({"name": account_name, "account_id": account_id, "status": "already_active"})
        return

    try:
        ce.update_cost_allocation_tags_status(
            CostAllocationTagsStatus=[{"TagKey": t, "Status": "Active"} for t in to_activate]
        )
        log.append(f"  [성공] {len(to_activate)}개 태그 활성화 완료")
        log.append("  [참고] 태그 데이터는 활성화 후 최대 24시간 후에 검색 가능합니다.")
    except ClientError as e:
        code = e.response["Error"]["Code"]
        log += [f"  [오류] 태그 활성화 실패: {code}", f"{'='*60}"]
        flush_log(log)
        record_result({"name": account_name, "account_id": account_id,
                       "status": "error", "error_reason": f"태그 활성화 실패 ({code})"})
        return

    log.append(f"{'='*60}")
    flush_log(log)
    record_result({"name": account_name, "account_id": account_id,
                   "status": "activated", "activated_tags": to_activate})


# ── click 커맨드 ───────────────────────────────────────────────────────────────

@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
def cmd(credentials_file, account_filter):
    """Cost Allocation 태그 활성화 (수업 전날 실행 권장)."""
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    click.echo(f"AWS 비용 할당 태그 활성화 시작\n활성화 대상: {', '.join(TARGET_TAGS)}\n")
    click.echo(f"총 {len(creds)}개의 계정을 처리합니다.\n")

    clear_results()
    run_parallel(_activate_tags, creds)

    results = get_results()
    activated   = sum(1 for r in results if r["status"] == "activated")
    already_ok  = sum(1 for r in results if r["status"] == "already_active")
    pending     = sum(1 for r in results if r["status"] == "pending")
    errors      = sum(1 for r in results if r["status"] == "error")
    click.echo(f"\n[요약] 활성화: {activated}개 / 이미 활성: {already_ok}개 / 반영 대기: {pending}개 / 오류: {errors}개")
    click.echo("\n모든 계정 처리 완료.")
