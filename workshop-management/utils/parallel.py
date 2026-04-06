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
import concurrent.futures
from typing import Callable

from utils.output import set_deferred_mode, flush_deferred_in_order


def run_parallel(
    fn: Callable[[dict], dict | None],
    credentials: list[dict],
    max_workers: int = 10,
) -> list[dict]:
    """
    credentials 리스트의 각 항목에 fn(cred)를 병렬 실행하고,
    None이 아닌 반환값을 모아 리스트로 반환한다.

    처리 중에는 진행률을 한 줄로만 표시하고,
    완료 후 계정 등록 순서대로 상세 로그를 출력한다.

    fn 시그니처:
      def fn(cred: dict) -> dict | None:
          # cred = {"access_key": ..., "secret_key": ..., "name": ...}
          ...

    반환값이 None이면 수집에서 제외된다 (결과가 없는 경우 등).
    """
    total = len(credentials)
    results = []

    # 지연 출력 모드 활성화 — 병렬 처리 중 로그를 계정별 버퍼에 저장한다
    set_deferred_mode(True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        # 각 계정의 처리 함수를 비동기로 제출 (제출 순서 = 계정 등록 순서)
        futures = {
            executor.submit(fn, cred): cred["name"]
            for cred in credentials
        }

        completed = 0
        for future in concurrent.futures.as_completed(futures):
            completed += 1
            pct = int(completed / total * 100)
            # \r로 커서를 줄 처음으로 이동해 같은 줄을 덮어쓴다
            sys.stderr.write(f"\r  처리 중... {completed}/{total} ({pct}%)")
            sys.stderr.flush()

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

    # 진행 표시 줄을 지우고 완료 메시지 출력
    sys.stderr.write(f"\r  처리 완료 ({total}/{total})\n")
    sys.stderr.flush()

    # 지연 출력 모드 해제 후 계정 등록 순서대로 로그를 출력한다
    set_deferred_mode(False)
    flush_deferred_in_order(credentials)

    return results
