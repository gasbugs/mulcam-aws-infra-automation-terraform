# =============================================================================
# commands/cleaners/network.py
# CloudFront, VPC, ELB, Route53, EIP 등 네트워크 리소스를 삭제한다.
# VPC 삭제 시 서브넷·IGW·NAT GW·라우팅 테이블·보안 그룹을 순서대로 정리한다.
# =============================================================================
from __future__ import annotations

import time

from botocore.exceptions import BotoCoreError, ClientError


def perform_cloudfront_cleanup(session, log: list) -> dict:
    """CloudFront 배포를 비활성화하고 삭제한다.
    Enabled 상태인 배포는 먼저 비활성화 요청을 보내고, Disabled 상태인 것만 즉시 삭제한다."""
    cf = session.client("cloudfront")
    result: dict = {"deleted": [], "disabled": [], "skipped": [], "failed": []}
    try:
        all_dists = []
        for page in cf.get_paginator("list_distributions").paginate():
            all_dists.extend(page.get("DistributionList", {}).get("Items", []))
    except ClientError as e:
        log.append(f"  [CloudFront 정리] 목록 조회 실패: {e}")
        return result
    for dist in all_dists:
        dist_id, enabled, status = dist["Id"], dist.get("Enabled", False), dist.get("Status", "")
        domain = dist.get("DomainName", "")
        if status == "InProgress":
            log.append(f"  [CloudFront 정리] 배포 진행 중 — 스킵: {dist_id}")
            result["skipped"].append(dist_id)
            continue
        if enabled:
            try:
                cfg_resp = cf.get_distribution_config(Id=dist_id)
                cfg = cfg_resp["DistributionConfig"]
                cfg["Enabled"] = False
                cf.update_distribution(Id=dist_id, DistributionConfig=cfg, IfMatch=cfg_resp["ETag"])
                log.append(f"  [CloudFront 정리] 비활성화 요청 완료: {dist_id} ({domain})")
                result["disabled"].append(dist_id)
            except ClientError as e:
                log.append(f"  [CloudFront 정리] 비활성화 실패 {dist_id}: {e}")
                result["failed"].append(dist_id)
        else:
            try:
                etag = cf.get_distribution(Id=dist_id)["ETag"]
                cf.delete_distribution(Id=dist_id, IfMatch=etag)
                log.append(f"  [CloudFront 정리] 삭제 완료: {dist_id} ({domain})")
                result["deleted"].append(dist_id)
            except ClientError as e:
                log.append(f"  [CloudFront 정리] 삭제 실패 {dist_id}: {e}")
                result["failed"].append(dist_id)
    return result


def perform_eip_cleanup(session, log: list, regions: list) -> dict:
    """EC2 인스턴스 종료 후 남은 EIP를 해제한다.
    NAT Gateway에 연결된 EIP는 건너뜀 — perform_vpc_cleanup에서 NAT GW 삭제 후 처리한다."""
    result: dict = {"released": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            addresses = ec2.describe_addresses().get("Addresses", [])
            for addr in addresses:
                alloc_id = addr.get("AllocationId")
                assoc_id = addr.get("AssociationId")
                eni_id    = addr.get("NetworkInterfaceId")
                if not alloc_id:
                    continue
                # NAT GW에 연결된 EIP인지 확인 — NAT GW ENI는 InterfaceType이 "nat_gateway"
                if eni_id:
                    try:
                        eni_type = ec2.describe_network_interfaces(
                            NetworkInterfaceIds=[eni_id]
                        )["NetworkInterfaces"][0].get("InterfaceType", "")
                        if eni_type == "nat_gateway":
                            log.append(f"  [EIP 정리] NAT GW EIP는 VPC 정리 단계에서 처리: {alloc_id}")
                            continue
                    except ClientError:
                        pass
                try:
                    # 인스턴스 등에 연결된 경우 먼저 분리 후 해제
                    if assoc_id:
                        ec2.disassociate_address(AssociationId=assoc_id)
                    ec2.release_address(AllocationId=alloc_id)
                    log.append(f"  [EIP 정리] 해제 완료: {alloc_id} (리전: {region})")
                    result["released"].append(alloc_id)
                except ClientError as e:
                    log.append(f"  [EIP 정리] 해제 실패 ({alloc_id}): {e}")
                    result["failed"].append(alloc_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_sg_cleanup(session, log: list, regions: list) -> dict:
    """default SG를 제외한 사용자 생성 보안 그룹을 모든 리전에서 삭제한다.
    SG 간 상호 참조 인그레스·이그레스 규칙을 먼저 제거해야 삭제가 가능하다.
    EC2·ELB·ECS 등 리소스 정리 후, VPC 삭제 전에 실행해야 한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            # default SG는 AWS가 자동 생성하므로 삭제 불가 — 탐지 대상에서 제외
            sgs = [sg for sg in ec2.describe_security_groups().get("SecurityGroups", [])
                   if sg.get("GroupName") != "default"]
            if not sgs:
                continue
            # 1단계: SG 간 상호 참조 규칙 제거 — A→B, B→A 참조가 남아 있으면 삭제 불가
            for sg in sgs:
                sg_id = sg["GroupId"]
                cross_in  = [r for r in sg.get("IpPermissions",       []) if r.get("UserIdGroupPairs")]
                cross_out = [r for r in sg.get("IpPermissionsEgress", []) if r.get("UserIdGroupPairs")]
                if cross_in:
                    try:
                        ec2.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=cross_in)
                    except ClientError:
                        pass
                if cross_out:
                    try:
                        ec2.revoke_security_group_egress(GroupId=sg_id, IpPermissions=cross_out)
                    except ClientError:
                        pass
            # 2단계: SG 삭제 — 아직 ENI에 연결된 SG는 ClientError로 실패하므로 실패 목록에 기록
            for sg in sgs:
                sg_id   = sg["GroupId"]
                sg_name = sg.get("GroupName", sg_id)
                try:
                    ec2.delete_security_group(GroupId=sg_id)
                    log.append(f"  [SG 정리] 삭제 완료: {sg_name} ({sg_id}, 리전: {region})")
                    result["deleted"].append(sg_id)
                except ClientError as e:
                    log.append(f"  [SG 정리] 삭제 실패 ({sg_name}, {sg_id}, 리전: {region}): {e}")
                    result["failed"].append(sg_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_nat_gateway_cleanup(session, log: list, regions: list) -> dict:
    """VPC와 무관하게 available/pending 상태의 NAT Gateway를 모두 삭제한다.
    삭제 완료 후 연결된 EIP도 해제한다. VPC 삭제 전에 실행해야 한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            nat_gws = ec2.describe_nat_gateways(
                Filters=[{"Name": "state", "Values": ["available", "pending"]}]
            ).get("NatGateways", [])
            if not nat_gws:
                continue
            nat_ids = [n["NatGatewayId"] for n in nat_gws]
            # 삭제 요청
            for nat_id in nat_ids:
                try:
                    ec2.delete_nat_gateway(NatGatewayId=nat_id)
                except ClientError as e:
                    log.append(f"  [NAT GW 정리] 삭제 요청 실패 ({nat_id}, 리전: {region}): {e}")
                    result["failed"].append(nat_id)
            # 삭제 완료까지 대기 (EIP 해제 가능 상태가 되려면 deleted 상태여야 함)
            try:
                waiter = ec2.get_waiter("nat_gateway_deleted")
                waiter.wait(
                    NatGatewayIds=nat_ids,
                    WaiterConfig={"Delay": 10, "MaxAttempts": 30},
                )
            except Exception:
                pass  # 타임아웃 시에도 EIP 해제 시도는 계속 진행
            # 연결됐던 EIP 해제
            for nat in nat_gws:
                nat_id = nat["NatGatewayId"]
                for addr in nat.get("NatGatewayAddresses", []):
                    alloc_id = addr.get("AllocationId")
                    if alloc_id:
                        try:
                            ec2.release_address(AllocationId=alloc_id)
                            log.append(f"  [NAT GW 정리] EIP 해제: {alloc_id} (리전: {region})")
                        except ClientError:
                            pass
                log.append(f"  [NAT GW 정리] 삭제 완료: {nat_id} (리전: {region})")
                result["deleted"].append(nat_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_vpc_cleanup(session, log: list, regions: list) -> dict:
    """기본(default) VPC를 제외한 모든 VPC를 삭제한다.
    NAT GW → IGW → 엔드포인트 → ENI → 서브넷 → 라우트 테이블 → 보안 그룹 → VPC 순으로 정리한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            vpcs = ec2.describe_vpcs(
                Filters=[{"Name": "is-default", "Values": ["false"]}]
            ).get("Vpcs", [])
            for vpc in vpcs:
                vpc_id = vpc["VpcId"]
                try:
                    # NAT Gateway 삭제 — 서브넷 삭제 전에 먼저 제거해야 서브넷이 지워짐
                    nat_gws = ec2.describe_nat_gateways(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]},
                                 {"Name": "state", "Values": ["available", "pending"]}]
                    ).get("NatGateways", [])
                    if nat_gws:
                        nat_ids = [n["NatGatewayId"] for n in nat_gws]
                        for nat_id in nat_ids:
                            ec2.delete_nat_gateway(NatGatewayId=nat_id)
                        # NAT GW가 완전히 삭제될 때까지 대기 (EIP 해제 가능 상태가 돼야 함)
                        waiter = ec2.get_waiter("nat_gateway_deleted")
                        waiter.wait(
                            NatGatewayIds=nat_ids,
                            WaiterConfig={"Delay": 10, "MaxAttempts": 30},
                        )
                        # NAT GW에 연결됐던 EIP 해제
                        for nat in nat_gws:
                            for addr in nat.get("NatGatewayAddresses", []):
                                alloc_id = addr.get("AllocationId")
                                if alloc_id:
                                    try:
                                        ec2.release_address(AllocationId=alloc_id)
                                        log.append(f"  [VPC 정리] NAT GW EIP 해제: {alloc_id} (리전: {region})")
                                    except ClientError:
                                        pass
                        log.append(f"  [VPC 정리] NAT Gateway 삭제 완료 ({len(nat_ids)}개, 리전: {region})")
                    # IGW 분리/삭제
                    for igw in ec2.describe_internet_gateways(
                        Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
                    ).get("InternetGateways", []):
                        ec2.detach_internet_gateway(InternetGatewayId=igw["InternetGatewayId"], VpcId=vpc_id)
                        ec2.delete_internet_gateway(InternetGatewayId=igw["InternetGatewayId"])
                    # VPC 엔드포인트 삭제
                    eps = ec2.describe_vpc_endpoints(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]},
                                 {"Name": "vpc-endpoint-state", "Values": ["available", "pending"]}]
                    ).get("VpcEndpoints", [])
                    if eps:
                        ec2.delete_vpc_endpoints(VpcEndpointIds=[ep["VpcEndpointId"] for ep in eps])
                    # 잔여 ENI 삭제 — Lambda/ALB 등이 생성한 인터페이스가 서브넷 삭제를 막음
                    # available 상태(어디에도 연결 안 된) ENI만 삭제 가능
                    for eni in ec2.describe_network_interfaces(
                        Filters=[{"Name": "vpc-id",  "Values": [vpc_id]},
                                 {"Name": "status",  "Values": ["available"]}]
                    ).get("NetworkInterfaces", []):
                        try:
                            ec2.delete_network_interface(NetworkInterfaceId=eni["NetworkInterfaceId"])
                            log.append(f"  [VPC 정리] 잔여 ENI 삭제: {eni['NetworkInterfaceId']} (리전: {region})")
                        except ClientError:
                            pass
                    # 서브넷 삭제
                    for subnet in ec2.describe_subnets(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
                    ).get("Subnets", []):
                        ec2.delete_subnet(SubnetId=subnet["SubnetId"])
                    # 비메인 라우트 테이블 삭제
                    for rt in ec2.describe_route_tables(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
                    ).get("RouteTables", []):
                        if not any(a.get("Main") for a in rt.get("Associations", [])):
                            ec2.delete_route_table(RouteTableId=rt["RouteTableId"])
                    # VPC 피어링 연결 종료 — 이 VPC가 requester 또는 accepter인 경우 모두 처리
                    for filters in [
                        [{"Name": "requester-vpc-info.vpc-id", "Values": [vpc_id]}],
                        [{"Name": "accepter-vpc-info.vpc-id",  "Values": [vpc_id]}],
                    ]:
                        for p in ec2.describe_vpc_peering_connections(
                            Filters=filters + [{"Name": "status-code",
                                                "Values": ["active", "pending-acceptance", "provisioning"]}]
                        ).get("VpcPeeringConnections", []):
                            try:
                                ec2.delete_vpc_peering_connection(
                                    VpcPeeringConnectionId=p["VpcPeeringConnectionId"])
                                log.append(f"  [VPC 정리] 피어링 연결 삭제: {p['VpcPeeringConnectionId']}")
                            except ClientError:
                                pass
                    # VPN Gateway 분리 — VGW가 연결된 채로는 VPC 삭제 불가
                    # detach_vpn_gateway는 비동기라 분리 완료까지 폴링해야 한다
                    for vgw in ec2.describe_vpn_gateways(
                        Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
                    ).get("VpnGateways", []):
                        vgw_id = vgw["VpnGatewayId"]
                        try:
                            ec2.detach_vpn_gateway(VpnGatewayId=vgw_id, VpcId=vpc_id)
                            log.append(f"  [VPC 정리] VPN Gateway 분리 요청: {vgw_id} (리전: {region})")
                        except ClientError:
                            pass
                        # 분리 완료까지 대기 (detaching → detached)
                        for _ in range(30):
                            time.sleep(5)
                            attachments = ec2.describe_vpn_gateways(
                                VpnGatewayIds=[vgw_id]
                            )["VpnGateways"][0].get("VpcAttachments", [])
                            still_attached = [
                                a for a in attachments
                                if a.get("VpcId") == vpc_id and a.get("State") != "detached"
                            ]
                            if not still_attached:
                                log.append(f"  [VPC 정리] VPN Gateway 분리 완료: {vgw_id}")
                                break
                        else:
                            log.append(f"  [VPC 정리] VPN Gateway 분리 대기 시간 초과: {vgw_id}")
                    # Egress-only IGW 삭제 (IPv6 아웃바운드 게이트웨이)
                    for eigw in ec2.describe_egress_only_internet_gateways(
                        Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
                    ).get("EgressOnlyInternetGateways", []):
                        try:
                            ec2.delete_egress_only_internet_gateway(
                                EgressOnlyInternetGatewayId=eigw["EgressOnlyInternetGatewayId"])
                        except ClientError:
                            pass
                    # 보안 그룹 간 상호 참조 규칙 제거 — SG-A↔SG-B 참조 시 삭제 불가
                    sgs = ec2.describe_security_groups(
                        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
                    ).get("SecurityGroups", [])
                    for sg in sgs:
                        sg_id = sg["GroupId"]
                        cross_in  = [r for r in sg.get("IpPermissions",       []) if r.get("UserIdGroupPairs")]
                        cross_out = [r for r in sg.get("IpPermissionsEgress", []) if r.get("UserIdGroupPairs")]
                        if cross_in:
                            try:
                                ec2.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=cross_in)
                            except ClientError:
                                pass
                        if cross_out:
                            try:
                                ec2.revoke_security_group_egress(GroupId=sg_id, IpPermissions=cross_out)
                            except ClientError:
                                pass
                    # 비기본 보안 그룹 삭제
                    for sg in sgs:
                        if sg["GroupName"] != "default":
                            try:
                                ec2.delete_security_group(GroupId=sg["GroupId"])
                            except ClientError:
                                pass
                    # VPC 삭제
                    ec2.delete_vpc(VpcId=vpc_id)
                    log.append(f"  [VPC 정리] VPC 삭제 완료: {vpc_id} (리전: {region})")
                    result["deleted"].append(vpc_id)
                except ClientError as e:
                    log.append(f"  [VPC 정리] VPC 삭제 실패 ({vpc_id}, 리전: {region}): {e}")
                    result["failed"].append(vpc_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_elb_cleanup(session, log: list, regions: list) -> dict:
    """ELB v1(Classic)과 v2(ALB/NLB) 로드 밸런서를 삭제한다.
    v2의 경우 리스너 → 타깃 그룹 → 로드 밸런서 순으로 삭제해야 한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        # Classic ELB (v1)
        try:
            elb = session.client("elb", region_name=region)
            lbs = elb.describe_load_balancers().get("LoadBalancerDescriptions", [])
            for lb in lbs:
                name = lb["LoadBalancerName"]
                try:
                    elb.delete_load_balancer(LoadBalancerName=name)
                    log.append(f"  [ELB 정리] Classic LB 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [ELB 정리] Classic LB 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
        # ALB/NLB (v2)
        try:
            elbv2 = session.client("elbv2", region_name=region)
            lbs = elbv2.describe_load_balancers().get("LoadBalancers", [])
            for lb in lbs:
                arn = lb["LoadBalancerArn"]
                name = lb.get("LoadBalancerName", arn)
                try:
                    # 리스너 삭제
                    listeners = elbv2.describe_listeners(LoadBalancerArn=arn).get("Listeners", [])
                    for listener in listeners:
                        try:
                            elbv2.delete_listener(ListenerArn=listener["ListenerArn"])
                        except ClientError:
                            pass
                    elbv2.delete_load_balancer(LoadBalancerArn=arn)
                    log.append(f"  [ELB 정리] ALB/NLB 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [ELB 정리] ALB/NLB 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
            # 타깃 그룹은 LB 삭제 후 별도 삭제 필요
            tgs = elbv2.describe_target_groups().get("TargetGroups", [])
            for tg in tgs:
                tg_arn = tg["TargetGroupArn"]
                tg_name = tg.get("TargetGroupName", tg_arn)
                try:
                    elbv2.delete_target_group(TargetGroupArn=tg_arn)
                    log.append(f"  [ELB 정리] 타깃 그룹 삭제 완료: {tg_name} (리전: {region})")
                    result["deleted"].append(tg_name)
                except ClientError:
                    pass  # 아직 사용 중일 수 있음 — 무시
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_route53_cleanup(session, log: list) -> dict:
    """Route53 호스팅 영역의 레코드를 삭제한 뒤 영역을 제거한다."""
    result: dict = {"deleted": [], "failed": []}
    try:
        r53 = session.client("route53")
        zones = r53.list_hosted_zones().get("HostedZones", [])
        for zone in zones:
            zone_id = zone["Id"].split("/")[-1]
            zone_name = zone["Name"].rstrip(".")
            try:
                # NS/SOA 이외의 레코드를 모두 삭제
                paginator = r53.get_paginator("list_resource_record_sets")
                changes = []
                for page in paginator.paginate(HostedZoneId=zone_id):
                    for rr in page.get("ResourceRecordSets", []):
                        if rr["Type"] in ("NS", "SOA"):
                            continue
                        changes.append({"Action": "DELETE", "ResourceRecordSet": rr})
                # 변경 사항을 500개씩 배치 적용 (API 제한)
                for i in range(0, len(changes), 500):
                    batch = changes[i:i+500]
                    if batch:
                        r53.change_resource_record_sets(
                            HostedZoneId=zone_id,
                            ChangeBatch={"Changes": batch}
                        )
                r53.delete_hosted_zone(Id=zone_id)
                log.append(f"  [Route53 정리] 호스팅 영역 삭제 완료: {zone_name}")
                result["deleted"].append(zone_name)
            except ClientError as e:
                log.append(f"  [Route53 정리] 호스팅 영역 삭제 실패 ({zone_name}): {e}")
                result["failed"].append(zone_name)
    except (ClientError, BotoCoreError):
        pass
    return result
