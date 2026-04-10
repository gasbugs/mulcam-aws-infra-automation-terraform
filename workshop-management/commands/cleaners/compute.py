# =============================================================================
# commands/cleaners/compute.py
# EC2, AMI, EBS, Lambda, ECS, EKS, ASG 등 컴퓨팅 리소스를 삭제한다.
# =============================================================================
from __future__ import annotations

import time

from botocore.exceptions import BotoCoreError, ClientError


def perform_lambda_cleanup(session, log: list, regions: list) -> dict:
    """모든 Lambda 함수를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            lam = session.client("lambda", region_name=region)
            functions = lam.list_functions().get("Functions", [])
            for fn in functions:
                fn_name = fn["FunctionName"]
                try:
                    lam.delete_function(FunctionName=fn_name)
                    log.append(f"  [Lambda 정리] 삭제 완료: {fn_name} (리전: {region})")
                    result["deleted"].append(fn_name)
                except ClientError as e:
                    log.append(f"  [Lambda 정리] 삭제 실패 ({fn_name}): {e}")
                    result["failed"].append(fn_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_ami_cleanup(session, log: list, regions: list) -> dict:
    """계정 소유의 AMI(Amazon Machine Image)를 해지(deregister)한다."""
    result: dict = {"deregistered": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            for image in ec2.describe_images(Owners=["self"]).get("Images", []):
                image_id = image["ImageId"]
                try:
                    ec2.deregister_image(ImageId=image_id)
                    log.append(f"  [AMI 정리] 해지 완료: {image_id} (리전: {region})")
                    result["deregistered"].append(image_id)
                except ClientError as e:
                    log.append(f"  [AMI 정리] 해지 실패 ({image_id}): {e}")
                    result["failed"].append(image_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_ebs_snapshot_cleanup(session, log: list, regions: list) -> dict:
    """계정 소유의 EBS 스냅샷을 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            for snap in ec2.describe_snapshots(OwnerIds=["self"]).get("Snapshots", []):
                snap_id = snap["SnapshotId"]
                try:
                    ec2.delete_snapshot(SnapshotId=snap_id)
                    log.append(f"  [스냅샷 정리] 삭제 완료: {snap_id} (리전: {region})")
                    result["deleted"].append(snap_id)
                except ClientError as e:
                    log.append(f"  [스냅샷 정리] 삭제 실패 ({snap_id}): {e}")
                    result["failed"].append(snap_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_ec2_cleanup(session, log: list, regions: list) -> dict:
    """EC2 인스턴스를 종료(terminate)하고 완전히 종료될 때까지 대기한다.
    EBS 볼륨·VPC 삭제보다 먼저 실행해야 한다."""
    result: dict = {"terminated": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            # 종료 전 상태의 인스턴스만 대상으로 조회
            reservations = ec2.describe_instances(Filters=[
                {"Name": "instance-state-name",
                 "Values": ["pending", "running", "stopping", "stopped"]}
            ]).get("Reservations", [])
            instance_ids = [i["InstanceId"] for r in reservations for i in r["Instances"]]
            if not instance_ids:
                continue
            try:
                ec2.terminate_instances(InstanceIds=instance_ids)
                log.append(f"  [EC2 정리] 종료 요청 완료 ({len(instance_ids)}개, 리전: {region}): "
                           f"{', '.join(instance_ids)}")
                # 종료 완료까지 대기 — EBS 볼륨이 available 상태로 전환돼야 삭제 가능
                waiter = ec2.get_waiter("instance_terminated")
                waiter.wait(
                    InstanceIds=instance_ids,
                    WaiterConfig={"Delay": 10, "MaxAttempts": 30},
                )
                for iid in instance_ids:
                    log.append(f"  [EC2 정리] 종료 확인: {iid} (리전: {region})")
                    result["terminated"].append(iid)
            except ClientError as e:
                log.append(f"  [EC2 정리] 종료 실패 (리전: {region}): {e}")
                result["failed"].extend(instance_ids)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_ebs_volume_cleanup(session, log: list, regions: list) -> dict:
    """available 상태의 EBS 볼륨을 삭제한다.
    EC2 인스턴스가 종료된 후에 실행해야 한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ec2 = session.client("ec2", region_name=region)
            # 인스턴스에 연결되지 않은 볼륨만 삭제 가능
            volumes = ec2.describe_volumes(
                Filters=[{"Name": "status", "Values": ["available"]}]
            ).get("Volumes", [])
            for vol in volumes:
                vol_id = vol["VolumeId"]
                try:
                    ec2.delete_volume(VolumeId=vol_id)
                    log.append(f"  [EBS 정리] 볼륨 삭제 완료: {vol_id} (리전: {region})")
                    result["deleted"].append(vol_id)
                except ClientError as e:
                    log.append(f"  [EBS 정리] 볼륨 삭제 실패 ({vol_id}): {e}")
                    result["failed"].append(vol_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_asg_cleanup(session, log: list, regions: list) -> dict:
    """Auto Scaling Group을 강제 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            asg = session.client("autoscaling", region_name=region)
            groups = asg.describe_auto_scaling_groups().get("AutoScalingGroups", [])
            for g in groups:
                name = g["AutoScalingGroupName"]
                try:
                    asg.delete_auto_scaling_group(AutoScalingGroupName=name, ForceDelete=True)
                    log.append(f"  [ASG 정리] 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [ASG 정리] 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_ecs_full_cleanup(session, log: list, regions: list) -> dict:
    """ECS 서비스를 중지하고, 태스크 정의를 해제한 뒤, 클러스터를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ecs = session.client("ecs", region_name=region)
            cluster_arns = ecs.list_clusters().get("clusterArns", [])
            for cluster_arn in cluster_arns:
                cluster_name = cluster_arn.rsplit("/", 1)[-1]
                try:
                    # 1) 서비스 스케일다운 후 삭제
                    service_arns = ecs.list_services(cluster=cluster_arn).get("serviceArns", [])
                    for svc_arn in service_arns:
                        svc_name = svc_arn.rsplit("/", 1)[-1]
                        try:
                            ecs.update_service(cluster=cluster_arn, service=svc_arn, desiredCount=0)
                            ecs.delete_service(cluster=cluster_arn, service=svc_arn, force=True)
                            log.append(f"  [ECS 정리] 서비스 삭제: {svc_name} (리전: {region})")
                        except ClientError:
                            pass

                    # 2) 실행 중인 태스크 중지
                    task_arns = ecs.list_tasks(cluster=cluster_arn).get("taskArns", [])
                    for task_arn in task_arns:
                        try:
                            ecs.stop_task(cluster=cluster_arn, task=task_arn, reason="workshop cleanup")
                        except ClientError:
                            pass

                    # 3) 태스크 정의 해제 (이 클러스터에서 사용된 모든 활성 정의)
                    td_arns = ecs.list_task_definitions(status="ACTIVE").get("taskDefinitionArns", [])
                    for td_arn in td_arns:
                        try:
                            ecs.deregister_task_definition(taskDefinition=td_arn)
                        except ClientError:
                            pass

                    # 4) 컨테이너 인스턴스 해제 (EC2 시작 유형)
                    ci_arns = ecs.list_container_instances(cluster=cluster_arn).get("containerInstanceArns", [])
                    for ci_arn in ci_arns:
                        try:
                            ecs.deregister_container_instance(cluster=cluster_arn,
                                                              containerInstance=ci_arn, force=True)
                        except ClientError:
                            pass

                    # 5) 클러스터 삭제
                    ecs.delete_cluster(cluster=cluster_arn)
                    log.append(f"  [ECS 정리] 클러스터 삭제 완료: {cluster_name} (리전: {region})")
                    result["deleted"].append(cluster_name)
                except ClientError as e:
                    log.append(f"  [ECS 정리] 클러스터 삭제 실패 ({cluster_name}): {e}")
                    result["failed"].append(cluster_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_eks_full_cleanup(session, log: list, regions: list) -> dict:
    """EKS 노드 그룹, Fargate 프로파일, 애드온을 삭제한 뒤 클러스터를 제거한다.
    각 단계는 비동기이므로 삭제 완료까지 폴링한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            eks = session.client("eks", region_name=region)
            clusters = eks.list_clusters().get("clusters", [])
            for cluster_name in clusters:
                try:
                    # 1) Fargate 프로파일 삭제
                    fps = eks.list_fargate_profiles(clusterName=cluster_name).get("fargateProfileNames", [])
                    for fp_name in fps:
                        try:
                            eks.delete_fargate_profile(clusterName=cluster_name, fargateProfileName=fp_name)
                            log.append(f"  [EKS 정리] Fargate 프로파일 삭제 요청: {fp_name}")
                        except ClientError:
                            pass
                    # Fargate 삭제 완료 대기
                    for _ in range(60):
                        remaining = eks.list_fargate_profiles(clusterName=cluster_name).get("fargateProfileNames", [])
                        if not remaining:
                            break
                        time.sleep(10)

                    # 2) 노드 그룹 삭제
                    ngs = eks.list_nodegroups(clusterName=cluster_name).get("nodegroups", [])
                    for ng_name in ngs:
                        try:
                            eks.delete_nodegroup(clusterName=cluster_name, nodegroupName=ng_name)
                            log.append(f"  [EKS 정리] 노드 그룹 삭제 요청: {ng_name}")
                        except ClientError:
                            pass
                    # 노드 그룹 삭제 완료 대기
                    for _ in range(90):
                        remaining = eks.list_nodegroups(clusterName=cluster_name).get("nodegroups", [])
                        if not remaining:
                            break
                        time.sleep(10)

                    # 3) 애드온 삭제
                    addons = eks.list_addons(clusterName=cluster_name).get("addons", [])
                    for addon_name in addons:
                        try:
                            eks.delete_addon(clusterName=cluster_name, addonName=addon_name)
                        except ClientError:
                            pass

                    # 4) 클러스터 삭제
                    eks.delete_cluster(name=cluster_name)
                    log.append(f"  [EKS 정리] 클러스터 삭제 요청: {cluster_name} (리전: {region})")
                    # 클러스터 삭제 완료 대기
                    for _ in range(90):
                        try:
                            eks.describe_cluster(name=cluster_name)
                            time.sleep(10)
                        except ClientError:
                            break
                    log.append(f"  [EKS 정리] 클러스터 삭제 완료: {cluster_name} (리전: {region})")
                    result["deleted"].append(cluster_name)
                except ClientError as e:
                    log.append(f"  [EKS 정리] 클러스터 삭제 실패 ({cluster_name}): {e}")
                    result["failed"].append(cluster_name)
        except (ClientError, BotoCoreError):
            pass
    return result
