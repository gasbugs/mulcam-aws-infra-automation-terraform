# =============================================================================
# utils/parallel.py
# concurrent.futures 병렬 처리 공통 모듈
#
# 계정별 프로그레스바(rich.Progress)를 표시하며 병렬 실행한다.
# fn 내부에서 cred["_update_progress"](pct, status) 를 호출해 상태를 갱신할 수 있다.
# =============================================================================
from __future__ import annotations

import concurrent.futures
import time
from typing import Callable

from rich.console import Console
from rich.console import Group
from rich.live import Live
from rich.progress import (
    BarColumn,
    Progress,
    SpinnerColumn,
    TaskProgressColumn,
    TextColumn,
)
from rich.text import Text

from utils.output import set_deferred_mode, flush_deferred_in_order

# 프로그레스바는 stderr에 출력 — 계정 상세 로그(stdout)와 분리
_progress_console = Console(stderr=True)


def run_parallel(
    fn: Callable[[dict], dict | None],
    credentials: list[dict],
    max_workers: int | None = None,
) -> list[dict]:
    """
    credentials 리스트의 각 항목에 fn(cred)를 병렬 실행하고,
    None이 아닌 반환값을 모아 리스트로 반환한다.

    계정별 프로그레스바를 표시하며, fn 내부에서 아래 콜백으로 상태를 갱신한다.
        cred["_update_progress"](pct: int, status: str)
          pct    — 0~100 정수 (진행률)
          status — 오른쪽에 표시할 상태 문자열

    완료 후 계정 등록 순서대로 상세 로그를 출력하고, 전체 소요 시간을 한 줄로 기록한다.
    """
    effective_workers = max_workers if max_workers is not None else len(credentials)
    results = []
    start_time = time.time()

    set_deferred_mode(True)

    # 계정별 프로그레스바 — 타이머 컬럼 없이 이름/바/퍼센트/상태만 표시
    progress = Progress(
        SpinnerColumn(),
        TextColumn("[bold]{task.fields[name]:<10}", justify="left"),
        BarColumn(bar_width=28),
        TaskProgressColumn(),
        TextColumn("  {task.fields[status]}"),
        console=_progress_console,
        transient=False,
    )

    task_ids: dict[str, int] = {}
    account_start: dict[str, float] = {}  # 계정별 처리 시작 시각

    for cred in credentials:
        tid = progress.add_task(
            description="",
            total=100,
            name=cred["name"],
            status="[dim]대기 중",
        )
        task_ids[cred["name"]] = tid

    def _make_updater(name: str) -> Callable[[int, str], None]:
        """계정별 프로그레스 갱신 콜백을 생성한다. rich는 내부적으로 스레드 안전."""
        tid = task_ids[name]
        def _update(pct: int, status: str) -> None:
            # 첫 갱신 시점을 시작 시각으로 기록한다
            if name not in account_start:
                account_start[name] = time.time()
            progress.update(tid, completed=pct, status=status)
        return _update

    enriched = [
        {**cred, "_update_progress": _make_updater(cred["name"])}
        for cred in credentials
    ]

    # 실시간으로 갱신되는 타이머 — __rich__ 가 렌더링마다 호출되어 경과 시간을 반영한다
    class _LiveTimer:
        def __rich__(self) -> Text:
            return Text(f"  경과: {time.time() - start_time:.1f}s", style="dim")

    # Progress 와 타이머를 하나의 Group 으로 묶어 Live 에 넘긴다
    # with progress: 대신 Live 를 직접 관리해야 두 렌더러블이 같은 화면에 출력된다
    with Live(Group(progress, _LiveTimer()), console=_progress_console,
              refresh_per_second=10, transient=False):
        with concurrent.futures.ThreadPoolExecutor(max_workers=effective_workers) as executor:
            futures = {
                executor.submit(fn, ec): ec["name"]
                for ec in enriched
            }

            for future in concurrent.futures.as_completed(futures):
                name = futures[future]
                # 시작 시각이 없으면(대기 중 바로 완료) 현재를 기준으로 계산
                elapsed = time.time() - account_start.get(name, start_time)
                try:
                    result = future.result()
                    if result is not None:
                        results.append(result)
                    progress.update(task_ids[name], completed=100,
                                    status=f"[green]완료 ✔[/green]  [dim]{elapsed:.1f}s[/dim]")
                except Exception as e:
                    progress.update(task_ids[name], completed=100,
                                    status=f"[red]오류 ✘[/red]  [dim]{elapsed:.1f}s[/dim]")
                    from utils.output import _deferred_logs, _deferred_lock
                    with _deferred_lock:
                        _deferred_logs.setdefault(name, []).append(
                            f"  [오류] {name} 처리 중 예외 발생: {e}"
                        )

    set_deferred_mode(False)
    flush_deferred_in_order(credentials)

    return results
