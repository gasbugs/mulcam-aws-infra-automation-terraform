# =============================================================================
# utils/output.py
# 출력 및 결과 수집 공통 모듈
#
# 기존 스크립트에 반복되던 아래 패턴을 이 모듈에서 통합 관리한다.
#   - flush_log()              : 스레드 안전 로그 출력 (지연 모드 지원)
#   - set_current_account()    : 현재 스레드의 계정 이름 등록
#   - set_deferred_mode()      : 지연 출력 모드 활성화/비활성화
#   - flush_deferred_in_order(): 계정 등록 순서대로 버퍼 로그 출력
#   - record_result()          : 스레드 안전 결과 수집
#   - _account_sort_key        : 계정 번호 기준 정렬 키
#   - print_table()            : rich 기반 결과 테이블 출력
#   - format_output()          : table / json / csv 출력 포맷 전환
# =============================================================================
from __future__ import annotations

import json
import csv
import io
import threading

try:
    # rich가 설치된 경우 컬러 테이블 사용
    from rich.console import Console
    from rich.table import Table
    _console = Console()
    _HAS_RICH = True
except ImportError:
    # rich가 없으면 일반 print로 폴백
    _HAS_RICH = False

# ── 스레드 안전 출력 락 ─────────────────────────────────────────────────────────
# 병렬 처리 시 여러 스레드의 출력이 뒤섞이지 않도록 단일 락을 공유한다.
_print_lock = threading.Lock()

# ── 지연 출력(deferred) 모드 상태 ──────────────────────────────────────────────
# 병렬 처리 중에는 로그를 계정별 버퍼에 저장해 두고,
# 처리 완료 후 계정 등록 순서대로 한꺼번에 출력한다.
_deferred_mode: bool = False
_deferred_logs: dict[str, list[str]] = {}   # 계정 이름 → 로그 라인 리스트
_deferred_lock = threading.Lock()

# ── 스레드 로컬 저장소 ─────────────────────────────────────────────────────────
# 각 스레드가 독립적으로 현재 처리 중인 계정 이름을 저장한다.
_thread_local = threading.local()


def set_current_account(name: str) -> None:
    """현재 스레드에서 처리 중인 계정 이름을 등록한다. 계정 핸들러 최상단에서 호출한다."""
    _thread_local.account_name = name


def set_deferred_mode(enabled: bool) -> None:
    """
    지연 출력 모드를 켜거나 끈다.
    True로 설정하면 flush_log() 호출 시 즉시 출력하지 않고 계정별 버퍼에 저장한다.
    활성화 시 기존 버퍼를 초기화한다.
    """
    global _deferred_mode, _deferred_logs
    _deferred_mode = enabled
    if enabled:
        with _deferred_lock:
            _deferred_logs = {}


def flush_deferred_in_order(credentials: list[dict]) -> None:
    """
    지연 저장된 계정별 로그를 credentials 리스트의 등록 순서대로 출력한다.
    병렬 처리 완료 후 run_parallel()에서 호출한다.
    """
    with _deferred_lock:
        # 현재 버퍼 스냅샷을 가져와 락을 빨리 해제한다
        logs = dict(_deferred_logs)

    for cred in credentials:
        name = cred["name"]
        if name in logs and logs[name]:
            # 계정 구분선을 추가해 출력 블록을 명확히 구분한다
            print("\n".join(logs[name]), flush=True)


def flush_log(lines: list[str]) -> None:
    """
    버퍼링된 로그 라인 목록을 출력한다.

    지연 모드(deferred)일 때는 현재 스레드의 계정 버퍼에 저장하고,
    일반 모드일 때는 락을 잡고 즉시 출력한다.
    """
    if _deferred_mode:
        # 현재 스레드가 처리 중인 계정 이름을 가져온다
        account_name = getattr(_thread_local, "account_name", "unknown")
        with _deferred_lock:
            if account_name not in _deferred_logs:
                _deferred_logs[account_name] = []
            _deferred_logs[account_name].extend(lines)
    else:
        with _print_lock:
            print("\n".join(lines), flush=True)


# ── 스레드 안전 결과 수집 ──────────────────────────────────────────────────────
# 각 계정의 처리 결과를 모아 요약 통계에 사용한다.
_results: list[dict] = []
_results_lock = threading.Lock()


def record_result(entry: dict) -> None:
    """처리 결과 dict를 스레드 안전하게 결과 리스트에 추가한다."""
    with _results_lock:
        _results.append(entry)


def get_results() -> list[dict]:
    """지금까지 수집된 결과 리스트의 복사본을 반환한다."""
    with _results_lock:
        return list(_results)


def clear_results() -> None:
    """결과 리스트를 초기화한다. 커맨드 재실행 시 사용한다."""
    with _results_lock:
        _results.clear()


# ── 정렬 헬퍼 ─────────────────────────────────────────────────────────────────

def account_sort_key(entry: dict) -> int:
    """
    '계정 3' 같은 이름에서 번호를 추출해 정렬 키로 반환한다.
    번호 추출에 실패하면 0을 반환해 앞쪽에 정렬한다.
    """
    try:
        return int(entry["name"].split()[-1])
    except (ValueError, IndexError, KeyError):
        return 0


# ── 테이블 출력 ────────────────────────────────────────────────────────────────

def print_table(results: list[dict], title: str = "") -> None:
    """
    결과 리스트를 테이블 형식으로 출력한다.
    rich가 설치된 경우 컬러 테이블, 없으면 단순 텍스트 테이블로 출력한다.
    """
    if not results:
        print(f"  [정보] {title} — 결과 없음")
        return

    if _HAS_RICH:
        # rich 컬러 테이블 출력
        table = Table(title=title, show_header=True, header_style="bold cyan")
        # 첫 번째 항목의 키를 컬럼으로 사용
        for key in results[0].keys():
            table.add_column(str(key))
        for row in results:
            table.add_row(*[str(v) for v in row.values()])
        _console.print(table)
    else:
        # rich 없을 때 단순 텍스트 출력
        if title:
            print(f"\n{'=' * 60}")
            print(f"  {title}")
            print(f"{'=' * 60}")
        headers = list(results[0].keys())
        col_widths = {h: max(len(h), max(len(str(r.get(h, ""))) for r in results)) for h in headers}
        header_line = "  " + "  ".join(h.ljust(col_widths[h]) for h in headers)
        print(header_line)
        print("  " + "-" * (len(header_line) - 2))
        for row in results:
            print("  " + "  ".join(str(row.get(h, "")).ljust(col_widths[h]) for h in headers))


def print_summary(results: list[dict], title: str = "[최종 통계 요약]") -> None:
    """
    결과 리스트의 status 필드 기준 간단 통계를 출력한다.
    status 값은 커맨드별로 다르므로 범용적으로 카운트만 출력한다.
    """
    from collections import Counter
    total = len(results)
    counter = Counter(r.get("status", "unknown") for r in results)

    lines = [
        "",
        "=" * 60,
        f"  {title}",
        "=" * 60,
        f"  전체 계정 수 : {total}개",
        f"  ─────────────────────────────────────",
    ]
    for status, count in sorted(counter.items()):
        lines.append(f"  {status:<20} : {count}개")
    lines.append("=" * 60)
    print("\n".join(lines))


# ── 포맷 변환 출력 ─────────────────────────────────────────────────────────────

def format_output(results: list[dict], fmt: str = "table", title: str = "") -> None:
    """
    --output 플래그에 따라 결과를 table / json / csv 형식으로 출력한다.

    fmt 값:
      "table"  — print_table() 호출 (기본값)
      "json"   — JSON 배열 출력
      "csv"    — CSV 헤더 + 데이터 출력
    """
    if fmt == "json":
        print(json.dumps(results, ensure_ascii=False, indent=2))
    elif fmt == "csv":
        if not results:
            return
        buf = io.StringIO()
        writer = csv.DictWriter(buf, fieldnames=results[0].keys())
        writer.writeheader()
        writer.writerows(results)
        print(buf.getvalue(), end="")
    else:
        # 기본값: table
        print_table(results, title=title)
