# =============================================================================
# utils/credentials.py
# accesskey.txt 파싱 공통 모듈
#
# 기존 스크립트 7개에 동일하게 복사되어 있던 parse_credentials() 함수를
# 이 모듈 하나에서 관리한다.
# =============================================================================
from __future__ import annotations

import sys


def load_credentials(file_path: str = "accesskey.txt") -> list[dict]:
    """
    accesskey.txt 파일을 파싱해 자격증명 dict 리스트를 반환한다.

    파일 형식: 탭으로 구분된 access_key와 secret_key (계정당 1줄)
      AKIA...  wJalr...

    반환 형식:
      [
        {"access_key": "AKIA...", "secret_key": "wJalr...", "name": "계정 1"},
        ...
      ]
    """
    credentials = []
    try:
        with open(file_path, "r") as f:
            for i, line in enumerate(f):
                line = line.strip()
                # 빈 줄과 주석(#으로 시작) 건너뜀
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    print(
                        f"경고: {file_path} 파일의 {i + 1}번째 줄 형식이 잘못되었습니다. "
                        f"(탭으로 구분 필요)"
                    )
                    continue
                credentials.append({
                    "access_key": parts[0].strip(),
                    "secret_key": parts[1].strip(),
                    # 계정 번호는 유효한 줄 기준으로 순서 부여
                    "name": f"계정 {len(credentials) + 1}",
                })
    except FileNotFoundError:
        print(
            f"오류: '{file_path}' 파일을 찾을 수 없습니다. "
            f"스크립트와 같은 위치에 파일을 생성하세요."
        )
        sys.exit(1)
    return credentials


def filter_credentials(credentials: list[dict], account_filter: str | None) -> list[dict]:
    """
    --filter 플래그 값으로 처리할 계정을 걸러낸다.

    account_filter 형식:
      "1-5"   → 계정 1, 2, 3, 4, 5
      "1,3,5" → 계정 1, 3, 5
      None    → 전체 계정

    계정 번호는 name 필드의 "계정 N"에서 N을 파싱한다.
    """
    if account_filter is None:
        return credentials

    # 포함할 계정 번호 집합 계산
    indices: set[int] = set()
    for part in account_filter.split(","):
        part = part.strip()
        if "-" in part:
            start, end = part.split("-", 1)
            indices.update(range(int(start), int(end) + 1))
        else:
            indices.add(int(part))

    return [c for c in credentials if _account_number(c) in indices]


def _account_number(cred: dict) -> int:
    """자격증명 dict의 name 필드에서 계정 번호를 추출한다."""
    try:
        return int(cred["name"].split()[-1])
    except (ValueError, IndexError, KeyError):
        return -1
