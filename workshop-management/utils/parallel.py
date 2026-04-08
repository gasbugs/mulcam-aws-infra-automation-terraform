# =============================================================================
# utils/parallel.py
# concurrent.futures 병렬 처리 공통 모듈
#
# 기존 스크립트 7개에 동일하게 반복되던 ThreadPoolExecutor 패턴을
# 이 모듈 하나에서 관리한다.
#
# 진행 표시 (지연 출력 모드):
#   - 병렬 처리 중에는 "처리 중... N/전체 (X%)" 한 줄만 표시한다.
#   - 처리 완료 후 계정 등록 순서대로 각 계정의 로그를 출력한다.
# =============================================================================
from __future__ import annotations

import sys
import time
import threading
import concurrent.futures
from typing import Callable

from utils.output import set_deferred_mode, flush_deferred_in_order


def _spinner_thread(stop_event: threading.Event, state: dict) -> None:
    """
    별도 스레드에서 스피너 애니메이션을 주기적으로 갱신한다.
    stop_event가 설정될 때까지 0.1초마다 현재 진행 상태를 다시 그린다.
    """
    # 스피너 프레임 순서 — ✻ 계열 유니코드 별 모양으로 회전 효과를 낸다
    frames = ["✻", "✼", "✽", "✾", "✽", "✼"]
    idx = 0
    while not stop_event.is_set():
        completed = state["completed"]
        total     = state["total"]
        elapsed   = time.time() - state["start"]
        pct       = int(completed / total * 100) if total else 0
        frame     = frames[idx % len(frames)]
        # \033[2K: 현재 줄 전체 지우기, \r: 줄 처음으로 이동 — 잔상 없이 덮어쓴다
        sys.stderr.write(
            f"\033[2K\r  {frame} 처리 중... {completed}/{total} ({pct}%)  {elapsed:.1f}s"
        )
        sys.stderr.flush()
        idx += 1
        time.sleep(0.1)


def run_parallel(
    fn: Callable[[dict], dict | None],
    credentials: list[dict],
    max_workers: int = 11,
) -> list[dict]:
    """
    credentials 리스트의 각 항목에 fn(cred)를 병렬 실행하고,
    None이 아닌 반환값을 모아 리스트로 반환한다.

    처리 중에는 스피너 + 진행률 + 경과 시간을 한 줄로만 표시하고,
    완료 후 계정 등록 순서대로 상세 로그를 출력한다.

    fn 시그니처:
      def fn(cred: dict) -> dict | None:
          # cred = {"access_key": ..., "secret_key": ..., "name": ...}
          ...

    반환값이 None이면 수집에서 제외된다 (결과가 없는 경우 등).
    """
    total = len(credentials)
    results = []

    # 스피너 스레드가 읽을 공유 상태 (GIL 덕분에 단순 dict로 충분)
    state = {"completed": 0, "total": total, "start": time.time()}

    # 지연 출력 모드 활성화 — 병렬 처리 중 로그를 계정별 버퍼에 저장한다
    set_deferred_mode(True)

    # 스피너 스레드 시작
    stop_event = threading.Event()
    spinner = threading.Thread(target=_spinner_thread, args=(stop_event, state), daemon=True)
    spinner.start()

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        # 각 계정의 처리 함수를 비동기로 제출 (제출 순서 = 계정 등록 순서)
        futures = {
            executor.submit(fn, cred): cred["name"]
            for cred in credentials
        }

        for future in concurrent.futures.as_completed(futures):
            # 완료 카운트를 갱신하면 스피너 스레드가 자동으로 반영한다
            state["completed"] += 1

            try:
                result = future.result()
                if result is not None:
                    results.append(result)
            except Exception as e:
                account_name = futures[future]
                # 오류도 해당 계정 버퍼에 기록되도록 deferred 모드 유지 중 직접 기록
                from utils.output import _deferred_logs, _deferred_lock
                with _deferred_lock:
                    if account_name not in _deferred_logs:
                        _deferred_logs[account_name] = []
                    _deferred_logs[account_name].append(
                        f"  [오류] {account_name} 처리 중 예외 발생: {e}"
                    )

    # 스피너 스레드를 중단하고 진행 표시 줄을 지운다
    stop_event.set()
    spinner.join()
    elapsed_total = time.time() - state["start"]
    sys.stderr.write(f"\033[2K\r  ✔ 완료 ({total}/{total})  {elapsed_total:.1f}s\n")
    sys.stderr.flush()

    # 지연 출력 모드 해제 후 계정 등록 순서대로 로그를 출력한다
    set_deferred_mode(False)
    flush_deferred_in_order(credentials)

    return results
