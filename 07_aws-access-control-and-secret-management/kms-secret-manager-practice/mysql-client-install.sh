# 1. MySQL 리포지토리 추가
sudo dnf install -y wget
wget https://repo.mysql.com/mysql80-community-release-el9-1.noarch.rpm
sudo dnf install -y mysql80-community-release-el9-1.noarch.rpm

# 2. 패키지 목록 업데이트
sudo dnf update -y

# 3. MySQL 클라이언트 설치
sudo dnf install -y mysql-community-client

# 4. 설치 확인
mysql --version