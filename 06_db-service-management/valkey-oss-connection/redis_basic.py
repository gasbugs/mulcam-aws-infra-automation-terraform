"""
[실습 1단계] Redis 기본 연결 및 읽기/쓰기

목적:
  - TLS와 AUTH 토큰을 사용해 ElastiCache(Valkey/Redis)에 안전하게 연결한다
  - set() 명령으로 데이터를 저장하고 get() 명령으로 조회하는 기본 흐름을 실습한다

사전 조건:
  - Terraform으로 ElastiCache Replication Group 및 EC2 배포 완료
  - EC2 인스턴스에서 실행 (Redis가 프라이빗 서브넷에 위치하므로 퍼블릭 접근 불가)
  - pip3 install redis

실행 방법:
  python3 redis_basic.py
"""

import redis

# Redis 클러스터 엔드포인트로 연결
redis_host = 'master.my-project-valkey.ygzznw.use1.cache.amazonaws.com'
redis_port = 6379
redis_auth_token = 'YourStrongAuthPassword123!'  # Terraform으로 설정한 패스워드

# TLS를 활성화하여 Redis 클라이언트 생성
client = redis.StrictRedis(
    host=redis_host,
    port=redis_port,
    ssl=True,  # TLS를 사용하여 연결
    password=redis_auth_token,  # AUTH 토큰 추가
    decode_responses=True
)

# 데이터 추가
client.set('mykey', 'Hello, Redis!')

# 데이터 읽기
value = client.get('mykey')
print(f"The value of 'mykey' is: {value}")
