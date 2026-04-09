##############################################################################
# [components.tf] AMI에 설치할 작업 단계 정의 (Packer의 provisioner에 해당)
#
# Image Builder Component는 AMI를 만들 때 실행할 셸 명령어 묶음입니다.
# Packer의 provisioner "shell" 블록과 같은 역할을 합니다.
# 이 파일에서 정의하는 것:
#   - Component 1: Java 17, Maven, Git 설치 + 앱 디렉토리 생성
#   - Component 2: CodeCommit clone → Maven 빌드 → JAR 복사 → systemd 서비스 등록
#
# 역할 연결: recipe.tf가 이 컴포넌트들을 순서대로 조합하여 레시피를 완성합니다.
##############################################################################

# Image Builder 컴포넌트 1 — 빌드 도구(Java 17, Maven, Git) 및 앱 디렉토리 설치
# CodeCommit에서 소스를 받아 빌드하려면 git과 maven이 모두 필요함
resource "aws_imagebuilder_component" "install_java17" {
  name        = "install-java17-${var.environment}-${random_string.suffix.result}"
  description = "Amazon Linux 2023에 Java 17(Corretto), Maven, Git을 설치하고 앱 디렉토리를 준비합니다"
  platform    = "Linux"
  version     = var.recipe_version

  data = yamlencode({
    schemaVersion = "1.0"
    phases = [
      {
        name = "build"
        steps = [
          {
            name   = "UpdatePackages"
            action = "ExecuteBash"
            inputs = {
              commands = ["sudo dnf update -y"]
            }
          },
          {
            name   = "InstallBuildTools"
            action = "ExecuteBash"
            inputs = {
              # Java 17 런타임 + Maven 빌드 도구 + Git 클라이언트 한 번에 설치
              commands = ["sudo dnf install -y java-17-amazon-corretto maven git"]
            }
          },
          {
            name   = "CreateAppDirectory"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "sudo mkdir -p /home/ec2-user/app",
                "sudo chown -R ec2-user:ec2-user /home/ec2-user/app"
              ]
            }
          }
        ]
      }
    ]
  })

  tags = {
    Name        = "install-java17"
    Environment = var.environment
  }
}

# Image Builder 컴포넌트 2 — CodeCommit에서 소스 clone → Maven 빌드 → systemd 서비스 등록
# Docker나 사전 빌드된 JAR 없이 Image Builder 인스턴스 내부에서 전체 빌드 파이프라인 수행
resource "aws_imagebuilder_component" "deploy_spring_app" {
  name        = "deploy-spring-app-${var.environment}-${random_string.suffix.result}"
  description = "CodeCommit에서 소스를 clone하여 Maven으로 JAR를 빌드하고 systemd 서비스로 등록합니다"
  platform    = "Linux"
  version     = var.recipe_version

  data = yamlencode({
    schemaVersion = "1.0"
    phases = [
      {
        name = "build"
        steps = [
          {
            name   = "CloneRepository"
            action = "ExecuteBash"
            inputs = {
              # AWSTOE는 root로 실행되지만 $HOME이 없음 — 명시적으로 설정 후 git 자격증명 도우미 구성
              # IAM 역할 기반으로 SSH 키 없이 CodeCommit HTTPS 인증 처리
              commands = [
                "export HOME=/root && git config --global credential.helper '!aws codecommit credential-helper $@' && git config --global credential.UseHttpPath true && git clone ${aws_codecommit_repository.spring_app.clone_url_http} /tmp/spring-app"
              ]
            }
          },
          {
            name   = "BuildJar"
            action = "ExecuteBash"
            inputs = {
              # Maven으로 JAR 빌드 — 단위 테스트도 함께 실행하여 코드 품질 검증
              commands = [
                "cd /tmp/spring-app && mvn clean package"
              ]
            }
          },
          {
            name   = "InstallJar"
            action = "ExecuteBash"
            inputs = {
              # 빌드된 JAR를 앱 실행 디렉토리로 복사하고 소유권 설정
              commands = [
                "cp /tmp/spring-app/target/demo-0.0.1-SNAPSHOT.jar /home/ec2-user/app/",
                "chown ec2-user:ec2-user /home/ec2-user/app/demo-0.0.1-SNAPSHOT.jar"
              ]
            }
          },
          {
            name   = "CleanupSource"
            action = "ExecuteBash"
            inputs = {
              # 소스코드와 Maven 캐시를 삭제 — AMI에 소스코드가 남으면 침해 시 코드 유출 위험
              commands = [
                "rm -rf /tmp/spring-app",
                "rm -rf /root/.m2"
              ]
            }
          },
          {
            name   = "CreateSystemdServiceFile"
            action = "ExecuteBash"
            inputs = {
              # systemd 서비스 파일 생성 — 부팅 시 Spring Boot 앱이 자동 실행되도록 등록
              commands = [
                <<-BASH
sudo tee /etc/systemd/system/spring-app.service > /dev/null << 'EOF'
[Unit]
Description=Spring Boot Application
Wants=network-online.target
After=network-online.target

[Service]
User=ec2-user
WorkingDirectory=/home/ec2-user/app
ExecStart=/usr/bin/java -jar /home/ec2-user/app/demo-0.0.1-SNAPSHOT.jar
SuccessExitStatus=143
TimeoutStopSec=10
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
BASH
              ]
            }
          },
          {
            name   = "EnableSpringAppService"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "sudo systemctl daemon-reload",
                "sudo systemctl enable spring-app.service"
              ]
            }
          }
        ]
      }
    ]
  })

  tags = {
    Name        = "deploy-spring-app"
    Environment = var.environment
  }
}
