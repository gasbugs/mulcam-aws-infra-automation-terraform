# netflux 애플리케이션을 위한 전용 네임스페이스 생성
# 네임스페이스는 Kubernetes 클러스터 안에서 리소스를 논리적으로 분리하는 단위
resource "kubernetes_namespace_v1" "netflux" {
  metadata {
    name = "netflux"
  }
  # module.eks 완료(time_sleep 30s 포함) 후 생성 — access entry 전파 대기를 위해 필수
  depends_on = [module.eks]
}

# Kubernetes 서비스: 외부에서 netflux 파드에 접근할 수 있도록 로드밸런서 생성
# LoadBalancer 타입은 AWS에서 자동으로 CLB(Classic Load Balancer)를 생성
resource "kubernetes_service_v1" "netflux_svc" {
  metadata {
    name      = "netflux-svc"
    namespace = kubernetes_namespace_v1.netflux.metadata[0].name
  }
  spec {
    selector = {
      app = "netflux" # 이 레이블을 가진 파드에 트래픽 전달
    }
    port {
      port        = 80   # 외부에서 접근하는 포트
      target_port = 5000 # Flask 앱이 사용하는 내부 포트
    }
    type = "LoadBalancer" # AWS CLB를 자동으로 프로비저닝
  }
}

# 생성된 CLB의 DNS 호스트명 정보를 가져오는 데이터 소스
data "kubernetes_service_v1" "netflux_svc" {
  metadata {
    name      = kubernetes_service_v1.netflux_svc.metadata[0].name
    namespace = kubernetes_namespace_v1.netflux.metadata[0].name
  }

  depends_on = [kubernetes_service_v1.netflux_svc]
}

# CLB 도메인 출력 (CloudFront 오리진으로 사용)
output "load_balancer_hostname" {
  description = "Hostname of the CLB created by the netflux Kubernetes LoadBalancer service"
  value       = data.kubernetes_service_v1.netflux_svc.status.0.load_balancer.0.ingress.0.hostname
}
