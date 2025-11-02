# 쿠버네티스 프로바이더 설정
provider "kubernetes" {
  config_path = "${pathexpand("~")}/.kube/config"
  # config_context = "your-context-name"
}

# 네임스페이스 생성
resource "kubernetes_namespace" "netflux" {
  metadata {
    name = "netflux"
  }
  depends_on = [null_resource.eks_kubectl_config]
}

# 쿠버네티스 서비스 리소스 생성
resource "kubernetes_service" "netflux_svc" {
  metadata {
    name      = "netflux-svc"
    namespace = kubernetes_namespace.netflux.metadata[0].name
  }
  spec {
    selector = {
      app = "netflux"
    }
    port {
      port        = 80
      target_port = 5000
    }
    type = "LoadBalancer"
  }
}

# CLB 도메인 정보 가져오기
data "kubernetes_service" "netflux_svc" {
  metadata {
    name      = kubernetes_service.netflux_svc.metadata[0].name
    namespace = kubernetes_namespace.netflux.metadata[0].name
  }

  depends_on = [kubernetes_service.netflux_svc]
}

# CLB 도메인 출력
output "load_balancer_hostname" {
  value = data.kubernetes_service.netflux_svc.status.0.load_balancer.0.ingress.0.hostname
}
