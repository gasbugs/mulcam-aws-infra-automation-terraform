# =============================================================================
# utils/session.py
# boto3 세션 생성 및 계정 ID 조회 공통 모듈
#
# 기존 스크립트 7개에 동일하게 복사되어 있던 get_account_id() 함수와
# boto3.Session 생성 패턴을 이 모듈에서 관리한다.
# =============================================================================
from __future__ import annotations

import boto3
from botocore.exceptions import ClientError


def make_session(access_key: str, secret_key: str) -> boto3.Session:
    """액세스 키와 시크릿 키로 boto3 세션을 생성한다."""
    return boto3.Session(
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )


def get_account_id(session: boto3.Session) -> str | None:
    """
    STS(Security Token Service)를 통해 현재 자격증명의 AWS 계정 ID를 조회한다.
    자격증명이 유효하지 않으면 None을 반환한다.
    """
    try:
        return session.client("sts").get_caller_identity()["Account"]
    except ClientError:
        return None
