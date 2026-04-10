# =============================================================================
# commands/cleaners/misc.py
# Image Builder, CodePipeline, CloudWatch, ACM, KMS, WAFv2 등
# 도메인 분류가 어려운 관리형 서비스 리소스를 삭제한다.
# =============================================================================
from __future__ import annotations

import time

from botocore.exceptions import BotoCoreError, ClientError


def _kms_is_disabled_customer_key(client, key_id: str) -> bool:
    """고객 관리형(CUSTOMER) KMS 키이면서 Disabled 상태인지 확인한다.
    AWS 관리형 키는 삭제 대상에서 제외하기 위해 KeyManager를 함께 검사한다."""
    try:
        meta = client.describe_key(KeyId=key_id).get("KeyMetadata", {})
        return meta.get("KeyManager") == "CUSTOMER" and meta.get("KeyState") == "Disabled"
    except ClientError:
        return False


def perform_cloudwatch_cleanup(session, log: list, regions: list) -> dict:
    """CloudWatch Logs 로그 그룹을 모두 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            logs_client = session.client("logs", region_name=region)
            paginator = logs_client.get_paginator("describe_log_groups")
            log_groups = []
            for page in paginator.paginate():
                log_groups.extend(page.get("logGroups", []))
            for lg in log_groups:
                lg_name = lg["logGroupName"]
                try:
                    logs_client.delete_log_group(logGroupName=lg_name)
                    log.append(f"  [CloudWatch 정리] 로그 그룹 삭제 완료: {lg_name} (리전: {region})")
                    result["deleted"].append(lg_name)
                except ClientError as e:
                    log.append(f"  [CloudWatch 정리] 로그 그룹 삭제 실패 ({lg_name}): {e}")
                    result["failed"].append(lg_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_apigateway_cleanup(session, log: list, regions: list) -> dict:
    """REST API(v1) 및 HTTP/WebSocket API(v2)를 모두 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        # REST APIs (v1)
        try:
            apigw = session.client("apigateway", region_name=region)
            rest_apis = apigw.get_rest_apis().get("items", [])
            for api in rest_apis:
                api_id = api["id"]
                try:
                    apigw.delete_rest_api(restApiId=api_id)
                    log.append(f"  [API Gateway 정리] REST API 삭제 완료: {api.get('name', api_id)} (리전: {region})")
                    result["deleted"].append(api_id)
                except ClientError as e:
                    log.append(f"  [API Gateway 정리] REST API 삭제 실패 ({api_id}): {e}")
                    result["failed"].append(api_id)
        except (ClientError, BotoCoreError):
            pass
        # HTTP/WebSocket APIs (v2)
        try:
            apigwv2 = session.client("apigatewayv2", region_name=region)
            http_apis = apigwv2.get_apis().get("Items", [])
            for api in http_apis:
                api_id = api["ApiId"]
                try:
                    apigwv2.delete_api(ApiId=api_id)
                    log.append(f"  [API Gateway 정리] HTTP/WS API 삭제 완료: {api.get('Name', api_id)} (리전: {region})")
                    result["deleted"].append(api_id)
                except ClientError as e:
                    log.append(f"  [API Gateway 정리] HTTP/WS API 삭제 실패 ({api_id}): {e}")
                    result["failed"].append(api_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_imagebuilder_cleanup(session, log: list, regions: list) -> dict:
    """Image Builder 파이프라인 → 레시피 → 컴포넌트 → 인프라 설정 → 배포 설정 순으로 삭제한다.
    파이프라인이 레시피·설정을 참조하므로 의존 순서를 지켜야 삭제가 가능하다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            ib = session.client("imagebuilder", region_name=region)

            # 0단계: 이미지(빌드 결과물) 삭제 — 파이프라인 실행으로 생성된 이미지가 남아있으면
            # 파이프라인 자체를 삭제할 수 없으므로(ResourceDependencyException) 가장 먼저 제거
            for image_version in ib.list_images(owner="Self").get("imageVersionList", []):
                image_version_arn = image_version["arn"]
                try:
                    builds = ib.list_image_build_versions(
                        imageVersionArn=image_version_arn
                    ).get("imageSummaryList", [])
                    for build in builds:
                        build_arn = build["arn"]
                        try:
                            ib.delete_image(imageBuildVersionArn=build_arn)
                            log.append(f"  [Image Builder 정리] 이미지 삭제 완료: {image_version['name']} (리전: {region})")
                            result["deleted"].append(build_arn)
                        except ClientError as e:
                            log.append(f"  [Image Builder 정리] 이미지 삭제 실패 ({build_arn}): {e}")
                            result["failed"].append(build_arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 이미지 빌드 버전 조회 실패 ({image_version_arn}): {e}")
                    result["failed"].append(image_version_arn)

            # 1단계: 파이프라인 삭제 — 레시피·인프라·배포 설정을 참조하므로 가장 먼저 삭제
            for pipeline in ib.list_image_pipelines().get("imagePipelineList", []):
                arn = pipeline["arn"]
                try:
                    ib.delete_image_pipeline(imagePipelineArn=arn)
                    log.append(f"  [Image Builder 정리] 파이프라인 삭제 완료: {pipeline['name']} (리전: {region})")
                    result["deleted"].append(arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 파이프라인 삭제 실패 ({arn}): {e}")
                    result["failed"].append(arn)

            # 2단계: 레시피 삭제 — 컴포넌트를 참조하므로 컴포넌트보다 먼저 삭제
            for recipe in ib.list_image_recipes(owner="Self").get("imageRecipeSummaryList", []):
                arn = recipe["arn"]
                try:
                    ib.delete_image_recipe(imageRecipeArn=arn)
                    log.append(f"  [Image Builder 정리] 레시피 삭제 완료: {recipe['name']} (리전: {region})")
                    result["deleted"].append(arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 레시피 삭제 실패 ({arn}): {e}")
                    result["failed"].append(arn)

            # 3단계: 컴포넌트 삭제 — 버전 ARN에서 빌드 버전 목록을 조회하여 삭제
            for comp_version in ib.list_components(owner="Self").get("componentVersionList", []):
                comp_version_arn = comp_version["arn"]
                try:
                    builds = ib.list_component_build_versions(
                        componentVersionArn=comp_version_arn
                    ).get("componentSummaryList", [])
                    for build in builds:
                        build_arn = build["arn"]
                        try:
                            ib.delete_component(componentBuildVersionArn=build_arn)
                            log.append(f"  [Image Builder 정리] 컴포넌트 삭제 완료: {comp_version['name']} (리전: {region})")
                            result["deleted"].append(build_arn)
                        except ClientError as e:
                            log.append(f"  [Image Builder 정리] 컴포넌트 삭제 실패 ({build_arn}): {e}")
                            result["failed"].append(build_arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 컴포넌트 빌드 버전 조회 실패 ({comp_version_arn}): {e}")
                    result["failed"].append(comp_version_arn)

            # 4단계: 인프라 설정 삭제
            for infra in ib.list_infrastructure_configurations().get("infrastructureConfigurationSummaryList", []):
                arn = infra["arn"]
                try:
                    ib.delete_infrastructure_configuration(infrastructureConfigurationArn=arn)
                    log.append(f"  [Image Builder 정리] 인프라 설정 삭제 완료: {infra['name']} (리전: {region})")
                    result["deleted"].append(arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 인프라 설정 삭제 실패 ({arn}): {e}")
                    result["failed"].append(arn)

            # 5단계: 배포 설정 삭제
            for dist in ib.list_distribution_configurations().get("distributionConfigurationSummaryList", []):
                arn = dist["arn"]
                try:
                    ib.delete_distribution_configuration(distributionConfigurationArn=arn)
                    log.append(f"  [Image Builder 정리] 배포 설정 삭제 완료: {dist['name']} (리전: {region})")
                    result["deleted"].append(arn)
                except ClientError as e:
                    log.append(f"  [Image Builder 정리] 배포 설정 삭제 실패 ({arn}): {e}")
                    result["failed"].append(arn)

        except (ClientError, BotoCoreError):
            pass
    return result


def perform_codecommit_cleanup(session, log: list, regions: list) -> dict:
    """CodeCommit 저장소를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            cc = session.client("codecommit", region_name=region)
            repos = cc.list_repositories().get("repositories", [])
            for repo in repos:
                repo_name = repo["repositoryName"]
                try:
                    cc.delete_repository(repositoryName=repo_name)
                    log.append(f"  [CodeCommit 정리] 저장소 삭제 완료: {repo_name} (리전: {region})")
                    result["deleted"].append(repo_name)
                except ClientError as e:
                    log.append(f"  [CodeCommit 정리] 저장소 삭제 실패 ({repo_name}): {e}")
                    result["failed"].append(repo_name)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_codepipeline_cleanup(session, log: list, regions: list) -> dict:
    """CodePipeline 파이프라인을 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            cp = session.client("codepipeline", region_name=region)
            pipelines = cp.list_pipelines().get("pipelines", [])
            for p in pipelines:
                name = p["name"]
                try:
                    cp.delete_pipeline(name=name)
                    log.append(f"  [CodePipeline 정리] 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [CodePipeline 정리] 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_cloudwatch_alarm_cleanup(session, log: list, regions: list) -> dict:
    """CloudWatch 메트릭 알람을 모두 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            cw = session.client("cloudwatch", region_name=region)
            paginator = cw.get_paginator("describe_alarms")
            alarm_names = []
            for page in paginator.paginate():
                alarm_names.extend(a["AlarmName"] for a in page.get("MetricAlarms", []))
            if not alarm_names:
                continue
            # delete_alarms는 최대 100개씩 배치 삭제 가능
            for i in range(0, len(alarm_names), 100):
                batch = alarm_names[i:i+100]
                try:
                    cw.delete_alarms(AlarmNames=batch)
                    log.append(f"  [CloudWatch Alarm 정리] 알람 {len(batch)}개 삭제 완료 (리전: {region})")
                    result["deleted"].extend(batch)
                except ClientError as e:
                    log.append(f"  [CloudWatch Alarm 정리] 알람 삭제 실패 (리전: {region}): {e}")
                    result["failed"].extend(batch)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_acm_cleanup(session, log: list, regions: list) -> dict:
    """ACM 인증서를 삭제한다. 사용 중인 인증서는 건너뛴다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            acm = session.client("acm", region_name=region)
            certs = acm.list_certificates().get("CertificateSummaryList", [])
            for cert in certs:
                arn = cert["CertificateArn"]
                domain = cert.get("DomainName", arn)
                # InUseBy가 비어있어야 삭제 가능
                try:
                    detail = acm.describe_certificate(CertificateArn=arn).get("Certificate", {})
                    if detail.get("InUseBy"):
                        log.append(f"  [ACM 정리] 사용 중 — 스킵: {domain} (리전: {region})")
                        continue
                except ClientError:
                    pass
                try:
                    acm.delete_certificate(CertificateArn=arn)
                    log.append(f"  [ACM 정리] 삭제 완료: {domain} (리전: {region})")
                    result["deleted"].append(domain)
                except ClientError as e:
                    log.append(f"  [ACM 정리] 삭제 실패 ({domain}): {e}")
                    result["failed"].append(domain)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_codebuild_cleanup(session, log: list, regions: list) -> dict:
    """CodeBuild 프로젝트를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            cb = session.client("codebuild", region_name=region)
            projects = cb.list_projects().get("projects", [])
            for name in projects:
                try:
                    cb.delete_project(name=name)
                    log.append(f"  [CodeBuild 정리] 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [CodeBuild 정리] 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_secretsmanager_cleanup(session, log: list, regions: list) -> dict:
    """Secrets Manager 시크릿을 즉시 삭제한다 (복구 기간 없이)."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            sm = session.client("secretsmanager", region_name=region)
            secrets = sm.list_secrets().get("SecretList", [])
            for secret in secrets:
                name = secret.get("Name", secret.get("ARN", "?"))
                try:
                    sm.delete_secret(SecretId=secret["ARN"], ForceDeleteWithoutRecovery=True)
                    log.append(f"  [Secrets Manager 정리] 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [Secrets Manager 정리] 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_kms_cleanup(session, log: list, regions: list) -> dict:
    """비활성화된 고객 관리형 KMS 키의 삭제를 예약한다 (7일 후 삭제)."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            kms = session.client("kms", region_name=region)
            keys = kms.list_keys().get("Keys", [])
            for key in keys:
                key_id = key["KeyId"]
                if not _kms_is_disabled_customer_key(kms, key_id):
                    continue
                try:
                    kms.schedule_key_deletion(KeyId=key_id, PendingWindowInDays=7)
                    log.append(f"  [KMS 정리] 삭제 예약 완료 (7일 후): {key_id} (리전: {region})")
                    result["deleted"].append(key_id)
                except ClientError as e:
                    log.append(f"  [KMS 정리] 삭제 예약 실패 ({key_id}): {e}")
                    result["failed"].append(key_id)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_wafv2_cleanup(session, log: list, regions: list) -> dict:
    """WAFv2 Web ACL을 삭제한다 (글로벌 + 리전)."""
    result: dict = {"deleted": [], "failed": []}
    # 글로벌 (CloudFront 연동)
    try:
        waf = session.client("wafv2", region_name="us-east-1")
        acls = waf.list_web_acls(Scope="CLOUDFRONT").get("WebACLs", [])
        for acl in acls:
            try:
                detail = waf.get_web_acl(Name=acl["Name"], Scope="CLOUDFRONT", Id=acl["Id"])
                lock_token = detail.get("LockToken")
                waf.delete_web_acl(Name=acl["Name"], Scope="CLOUDFRONT", Id=acl["Id"], LockToken=lock_token)
                log.append(f"  [WAFv2 정리] 글로벌 ACL 삭제 완료: {acl['Name']}")
                result["deleted"].append(acl["Name"])
            except ClientError as e:
                log.append(f"  [WAFv2 정리] 글로벌 ACL 삭제 실패 ({acl['Name']}): {e}")
                result["failed"].append(acl["Name"])
    except (ClientError, BotoCoreError):
        pass
    # 리전별
    for region in regions:
        try:
            waf = session.client("wafv2", region_name=region)
            acls = waf.list_web_acls(Scope="REGIONAL").get("WebACLs", [])
            for acl in acls:
                try:
                    detail = waf.get_web_acl(Name=acl["Name"], Scope="REGIONAL", Id=acl["Id"])
                    lock_token = detail.get("LockToken")
                    waf.delete_web_acl(Name=acl["Name"], Scope="REGIONAL", Id=acl["Id"], LockToken=lock_token)
                    log.append(f"  [WAFv2 정리] ACL 삭제 완료: {acl['Name']} (리전: {region})")
                    result["deleted"].append(acl["Name"])
                except ClientError as e:
                    log.append(f"  [WAFv2 정리] ACL 삭제 실패 ({acl['Name']}): {e}")
                    result["failed"].append(acl["Name"])
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_sns_cleanup(session, log: list, regions: list) -> dict:
    """SNS 토픽을 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            sns = session.client("sns", region_name=region)
            topics = sns.list_topics().get("Topics", [])
            for t in topics:
                arn = t["TopicArn"]
                name = arn.rsplit(":", 1)[-1]
                try:
                    sns.delete_topic(TopicArn=arn)
                    log.append(f"  [SNS 정리] 토픽 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [SNS 정리] 토픽 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result


def perform_sqs_cleanup(session, log: list, regions: list) -> dict:
    """SQS 큐를 삭제한다."""
    result: dict = {"deleted": [], "failed": []}
    for region in regions:
        try:
            sqs = session.client("sqs", region_name=region)
            urls = sqs.list_queues().get("QueueUrls", [])
            for url in urls:
                name = url.rsplit("/", 1)[-1]
                try:
                    sqs.delete_queue(QueueUrl=url)
                    log.append(f"  [SQS 정리] 큐 삭제 완료: {name} (리전: {region})")
                    result["deleted"].append(name)
                except ClientError as e:
                    log.append(f"  [SQS 정리] 큐 삭제 실패 ({name}): {e}")
                    result["failed"].append(name)
        except (ClientError, BotoCoreError):
            pass
    return result
