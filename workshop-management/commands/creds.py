# 생성된 크레덴셜 CSV 목록 및 내용 출력 커맨드
import click


@click.command()
@click.option("--output", "-o", "output_fmt",
              type=click.Choice(["table", "json", "csv"]), default="table", show_default=True,
              help="출력 포맷")
def cmd(output_fmt):
    """생성된 크레덴셜 CSV 목록 및 내용 출력."""
    click.echo("[creds] 아직 구현되지 않았습니다.")
