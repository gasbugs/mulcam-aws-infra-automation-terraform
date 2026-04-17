# =============================================================================
# commands/vpc.py
# awsw vpc — 각 계정의 지정 리전에 Default VPC + Default 서브넷을 복원한다.
#
# AWS 계정에서 Default VPC가 삭제된 경우(예: aws-nuke 실행 후) 이 명령으로 복원한다.
# Default VPC가 이미 존재하면 건너뛰고, 없으면 create_default_vpc API로 생성한다.
# VPC는 생성되었으나 일부 AZ에 서브넷이 없는 경우에도 자동으로 보완한다.
# =============================================================================
from __future__ import annotations

from functools import partial

import click
from botocore.exceptions import ClientError

from utils.credentials import filter_credentials, load_credentials
from utils.output import flush_log, set_current_account
from utils.parallel import run_parallel
from utils.session import get_account_id, make_session

# 기본 대상 리전 — nuke 이후 복원 시나리오에서 us-east-1이 주 대상
_DEFAULT_REGIONS = ["us-east-1"]


# ── VPC 헬퍼 ──────────────────────────────────────────────────────────────────

def _get_default_vpc_id(ec2, log: list) -> str | None:
    """현재 리전의 Default VPC ID를 반환한다. 없으면 None."""
    try:
        vpcs = ec2.describe_vpcs(
            Filters=[{"Name": "isDefault", "Values": ["true"]}]
        )["Vpcs"]
        return vpcs[0]["VpcId"] if vpcs else None
    except ClientError as e:
        log.append(f"  [오류] VPC 조회 실패: {e}")
        return None


def _create_default_vpc(ec2, log: list) -> str | None:
    """Default VPC를 생성하고 VPC ID를 반환한다. 실패 시 None."""
    try:
        vpc_id = ec2.create_default_vpc()["Vpc"]["VpcId"]
        log.append(f"  [생성] Default VPC 생성 완료: {vpc_id}")
        return vpc_id
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "DefaultVpcAlreadyExists":
            # 생성 시도 직전 다른 스레드가 먼저 만든 경우 — 다시 조회
            return _get_default_vpc_id(ec2, log)
        log.append(f"  [오류] Default VPC 생성 실패({code}): {e}")
        return None


def _ensure_default_subnets(ec2, vpc_id: str, log: list) -> None:
    """
    모든 가용 영역(AZ)에 Default 서브넷이 존재하는지 확인하고,
    없는 AZ에 대해 create_default_subnet을 호출한다.

    create_default_vpc() 호출 시 보통 자동 생성되지만,
    VPC만 존재하고 서브넷이 누락된 경우를 대비해 명시적으로 보완한다.
    """
    try:
        # 현재 리전의 모든 가용 영역 목록
        azs = [
            az["ZoneName"]
            for az in ec2.describe_availability_zones(
                Filters=[{"Name": "state", "Values": ["available"]}]
            )["AvailabilityZones"]
            if az["ZoneType"] == "availability-zone"  # Local Zone, Wavelength Zone 제외
        ]
    except ClientError as e:
        log.append(f"  [오류] 가용 영역 조회 실패: {e}")
        return

    # Default VPC에 이미 존재하는 서브넷의 AZ 목록
    try:
        existing_azs = {
            sn["AvailabilityZone"]
            for sn in ec2.describe_subnets(
                Filters=[
                    {"Name": "vpc-id", "Values": [vpc_id]},
                    {"Name": "defaultForAz", "Values": ["true"]},
                ]
            )["Subnets"]
        }
    except ClientError as e:
        log.append(f"  [오류] 서브넷 조회 실패: {e}")
        return

    # 서브넷이 없는 AZ에 Default 서브넷 생성
    missing_azs = [az for az in azs if az not in existing_azs]
    if not missing_azs:
        log.append(f"  [확인] 모든 AZ에 Default 서브넷 존재 ({len(existing_azs)}개)")
        return

    for az in missing_azs:
        try:
            sn = ec2.create_default_subnet(AvailabilityZone=az)["Subnet"]
            log.append(f"  [생성] Default 서브넷 생성: {sn['SubnetId']} ({az})")
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code == "DefaultSubnetAlreadyExistsInAvailabilityZone":
                log.append(f"  [확인] 서브넷 이미 존재: {az}")
            else:
                log.append(f"  [오류] 서브넷 생성 실패 ({az}, {code}): {e}")


def ensure_default_vpc_in_region(session, region: str, log: list) -> str:
    """
    단일 리전에 대해 Default VPC + 서브넷을 보장한다.
    반환값: "존재함" | "생성됨" | "실패: <이유>"
    """
    try:
        ec2 = session.client("ec2", region_name=region)
        vpc_id = _get_default_vpc_id(ec2, log)

        if vpc_id:
            log.append(f"  [확인] Default VPC 이미 존재: {vpc_id} (리전: {region})")
            created = False
        else:
            log.append(f"  [시작] Default VPC 없음 — 생성 시작 (리전: {region})")
            vpc_id = _create_default_vpc(ec2, log)
            created = True

        if not vpc_id:
            return "실패: VPC ID 없음"

        _ensure_default_subnets(ec2, vpc_id, log)
        return "생성됨" if created else "존재함"

    except Exception as e:
        return f"실패: {e}"


# ── 계정별 처리 ────────────────────────────────────────────────────────────────

def _restore_vpc(cred: dict, regions: list[str]) -> None:
    """단일 계정의 지정 리전들에 Default VPC + 서브넷을 복원한다."""
    set_current_account(cred["name"])
    account_name = cred["name"]
    log = [f"{'='*60}", f"  [{account_name} / Key: {cred['access_key'][:5]}...] VPC 복원 시작"]

    session = make_session(cred["access_key"], cred["secret_key"])
    account_id = get_account_id(session)
    if not account_id:
        log += ["  [오류] 계정 ID 조회 실패 — 자격증명을 확인하세요.", f"{'='*60}"]
        flush_log(log)
        return

    log.append(f"  계정 ID: {account_id} | 대상 리전: {', '.join(regions)}")

    for region in regions:
        result = ensure_default_vpc_in_region(session, region, log)
        log.append(f"  [결과] {region}: {result}")

    log += [f"  [{account_name}] VPC 복원 완료", f"{'='*60}"]
    flush_log(log)


# ── click 커맨드 ───────────────────────────────────────────────────────────────

@click.command()
@click.option("--credentials-file", "-c", default="accesskey.txt", show_default=True,
              help="자격증명 파일 경로 (탭 구분 access_key + secret_key)")
@click.option("--filter", "-f", "account_filter", default=None,
              help="처리할 계정 범위 (예: 1-5, 1,3,5). 미지정 시 전체 계정")
@click.option("--region", "-r", multiple=True, default=None,
              help=f"대상 리전 (여러 번 지정 가능). 미지정 시 기본값: {', '.join(_DEFAULT_REGIONS)}")
def cmd(credentials_file, account_filter, region):
    """
    각 계정에 Default VPC + Default 서브넷을 복원한다.

    \b
    aws-nuke 실행 후 Default VPC가 삭제된 경우 이 명령으로 복원한다.
    Default VPC가 이미 존재하면 건너뛰고, 없으면 새로 생성한다.

    \b
    예시:
      awsw vpc                      # 전체 계정 us-east-1 복원
      awsw vpc -f 1-3               # 계정 1~3만 복원
      awsw vpc -r us-east-1 -r ap-northeast-2   # 복수 리전 복원
    """
    regions = list(region) if region else _DEFAULT_REGIONS

    creds = filter_credentials(load_credentials(credentials_file), account_filter)
    if not creds:
        click.echo("처리할 계정 정보가 없습니다. accesskey.txt 파일을 확인하세요.")
        return

    click.echo(f"Default VPC 복원 시작 — 총 {len(creds)}개 계정 | 리전: {', '.join(regions)}\n")
    worker = partial(_restore_vpc, regions=regions)
    run_parallel(worker, creds)
    click.echo("\n모든 계정 VPC 복원 완료.")
