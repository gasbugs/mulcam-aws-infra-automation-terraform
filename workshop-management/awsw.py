#!/usr/bin/env python3
# =============================================================================
# awsw.py — AWS 워크샵 운영 CLI 진입점
#
# 사용법: python awsw.py <command> [options]
# 패키징 후: awsw <command> [options]
#
# 커맨드 목록:
#   setup     수강생 IAM 유저 생성 + 정책 연결 + CSV 출력
#   teardown  수강생 IAM 유저 완전 삭제
#   audit     잔여 리소스 스캔 후 스냅샷 저장
#   clean     스냅샷 기반 잔여 리소스 삭제 + 이력 저장
#   cost      전일 비용 리포트
#   check     CloudFront / ALB 서비스 한도 점검
#   tag       Cost Allocation 태그 활성화
#   admin     terraform-user-0 어드민 권한 보장
#   status    각 계정의 유저/정책 연결 상태 조회
#   creds     생성된 크레덴셜 CSV 목록 및 내용 출력
#   pre       수업 전 준비 일괄 실행 (tag → admin → check)
#   post      수업 후 정리 일괄 실행 (audit → clean → teardown)
# =============================================================================
import click

from commands import setup, teardown, audit, clean, cost, check, tag, admin, status, creds, workflow


@click.group()
@click.version_option(version="0.1.0", prog_name="awsw")
def cli():
    """AWS 워크샵 운영 CLI — 계정 관리, 리소스 감사, 비용 모니터링을 단일 도구로."""


# ── 커맨드 등록 ────────────────────────────────────────────────────────────────
cli.add_command(setup.cmd,       name="setup")
cli.add_command(teardown.cmd,    name="teardown")
cli.add_command(audit.cmd,       name="audit")
cli.add_command(clean.cmd,       name="clean")
cli.add_command(cost.cmd,        name="cost")
cli.add_command(check.cmd,       name="check")
cli.add_command(tag.cmd,         name="tag")
cli.add_command(admin.cmd,       name="admin")
cli.add_command(status.cmd,      name="status")
cli.add_command(creds.cmd,       name="creds")
cli.add_command(workflow.pre,    name="pre")
cli.add_command(workflow.post,   name="post")


if __name__ == "__main__":
    cli()
