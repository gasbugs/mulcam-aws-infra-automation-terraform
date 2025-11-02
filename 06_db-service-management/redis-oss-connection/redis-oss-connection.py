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
