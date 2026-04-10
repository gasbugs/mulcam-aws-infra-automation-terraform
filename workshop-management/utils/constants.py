# =============================================================================
# utils/constants.py
# awsw 전역 상수 — 여러 커맨드에서 공유하는 상수를 한 곳에 정의한다
# =============================================================================

# 워크샵 기본 계정 유저 — 삭제 대상에서 반드시 제외해야 한다
EXPECTED_IAM_USERS: frozenset[str] = frozenset({"terraform-user-0", "terraform-user-1"})

# 워크샵 관리용 보호 정책 — 학생이 만든 정책과 구별해 삭제 제외한다
PROTECTED_IAM_POLICIES: frozenset[str] = frozenset({"TerraformWorkshop-Restricted-us-east-1"})
