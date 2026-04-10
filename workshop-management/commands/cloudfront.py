# =============================================================================
# commands/cloudfront.py
# awsw cf — CloudFront 배포 비활성화 및 삭제
#
# CloudFront 배포를 완전히 해지하려면 두 단계가 필요하다:
#   1단계: Enabled 상태인 배포를 비활성화(Disabled)로 변경 요청
#   2단계: AWS가 비활성화를 전파(약 15~30분)한 뒤 다시 실행하면 삭제 완료
#
# 사용 예:
#   awsw cf                  # 전체 계정 실행
#   awsw cf -f 1-5           # 1~5번 계정만 실행
#   awsw cf --yes            # 확인 프롬프트 생략
# =============================================================================
from __future__ import annotations

import click

from commands.cleaners.network import perform_cloudfront_cleanup
from utils.credentials import filter_credentials, load_credentials
from utils.output import (
    account_sort_key, clear_results, flush_log, get_results,
    record_result, set_current_account,
)
from utils.parallel import run_parallel
from utils.session import make_session


def _process_account(cred: dict) -> None:
    """단일 계정의 CloudFront 배포를 비활성화/삭제한다."""
    update_fn = cred.get("_update_progress")
    set_current_account(cred["name"])
    account_name = cred["name"]

    log = ["", f"{'='*60}", f"  [{account_name}] CloudFront 정리 시작"]
    if update_fn:
        update_fn(10, "CloudFront 목록 조회 중")

    session = make_session(cred["access_key"], cred["secret_key"])

    if update_fn:
        update_fn(30, "CloudFront 비활성화/삭제 처리 중")

    # CloudFront 비활성화(Enabled→false) 및 삭제(Disabled 상태) 수행
    cf_result = perform_cloudfront_cleanup(session, log)

    if update_fn:
        update_fn(100, "완료")

    log.append(f"  [{account_name}] CloudFront 정리 완료")
    log.append(f"{'='*60}")
    flush_log(log)
    record_result({"name": account_name, "cf_cleanup": cf_result})


def _print_summary() -> None:
    """전체 계정의 CloudFront 처리 결과를 요약 출력한다."""
    results = get_results()

    # 계정별 집계
    total_deleted  = sum(len(r.get("cf_cleanup", {}).get("deleted",  [])) for r in results)
    total_disabled = sum(len(r.get("cf_cleanup", {}).get("disabled", [])) for r in results)
    total_skipped  = sum(len(r.get("cf_cleanup", {}).get("skipped",  [])) for r in results)
    total_failed   = sum(len(r.get("cf_cleanup", {}).get("failed",   [])) for r in results)

    lines = [
        "",
        "=" * 60,
        "  [CloudFront 처리 결과 요약]",
        "=" * 60,
    ]

    if total_deleted:
        lines.append(f"  · 삭제 완료          : {total_deleted}개")
    if total_disabled:
        lines.append(f"  · 비활성화 요청 완료 : {total_disabled}개  ← 15~30분 후 재실행 필요")
    if total_skipped:
        lines.append(f"  · 진행 중 스킵       : {total_skipped}개")
    if total_failed:
        lines.append(f"  · 처리 실패          : {total_failed}개")
    if not any([total_deleted, total_disabled, total_skipped, total_failed]):
        lines.append("  CloudFront 배포가 없습니다.")

    # 비활성화만 완료된 계정 목록 — 재실행이 필요함을 알린다
    disabled_accounts = [
        r for r in results if r.get("cf_cleanup", {}).get("disabled")
    ]
    if disabled_accounts:
        lines += [
            "",
            "=" * 60,
            "  [재실행 필요 계정 — 비활성화 전파 대기 중]",
            "  AWS 전파에 약 15~30분이 소요됩니다.",
            "  완료 후 'awsw cf' 를 다시 실행하면 삭제됩니다.",
            "=" * 60,
        ]
        for r in sorted(disabled_accounts, key=account_sort_key):
            ids = ", ".join(r["cf_cleanup"]["disabled"])
            lines.append(f"  {r['name']:<10}  배포 ID: {ids}")

    lines.append("=" * 60)
    print("\n".join(lines))


@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
@click.option("--yes", "-y", is_flag=True, help="실행 확인 프롬프트 생략")
def cmd(credentials_file, account_filter, yes):
    """CloudFront 배포 비활성화 및 삭제.

    \b
    1단계(첫 실행): Enabled 배포 → 비활성화 요청
    2단계(재실행):  Disabled 배포 → 완전 삭제
    InProgress 상태인 배포는 자동으로 건너뜁니다.
    """
    # 자격증명 로드 및 필터 적용
    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다.")
        return

    click.echo(f"\n[CloudFront 정리] 대상 계정: {len(creds)}개\n")
    click.echo("  · Enabled 배포  → 비활성화 요청 (15~30분 후 재실행하면 삭제)")
    click.echo("  · Disabled 배포 → 즉시 삭제")
    click.echo()

    # 실행 확인
    if not yes:
        try:
            click.confirm(
                f"위 {len(creds)}개 계정의 CloudFront 배포를 처리하시겠습니까?",
                abort=True,
            )
        except click.exceptions.Abort:
            click.echo("\n취소됐습니다.")
            return

    click.echo()
    clear_results()
    run_parallel(_process_account, creds)
    _print_summary()
