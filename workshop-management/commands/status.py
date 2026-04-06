# 각 계정의 유저/정책 연결 상태 조회 커맨드
import click


@click.command()
@click.option("--credentials-file", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5)")
@click.option("--output", "-o", "output_fmt",
              type=click.Choice(["table", "json", "csv"]), default="table", show_default=True,
              help="출력 포맷")
def cmd(credentials_file, account_filter, output_fmt):
    """각 계정의 IAM 유저/정책 연결 상태 조회."""
    click.echo("[status] 아직 구현되지 않았습니다.")
