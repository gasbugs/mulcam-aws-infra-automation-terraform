# 수업 전/후 일괄 실행 워크플로우 커맨드 (pre / post)
import click


@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
def pre(credentials_file, account_filter):
    """수업 전 준비 일괄 실행 (tag → admin → check)."""
    click.echo("[pre] 아직 구현되지 않았습니다.")


@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
@click.option("--yes", "-y", is_flag=True, help="삭제 확인 프롬프트 생략")
def post(credentials_file, account_filter, yes):
    """수업 후 정리 일괄 실행 (audit → clean → teardown)."""
    click.echo("[post] 아직 구현되지 않았습니다.")
