import time
import redis
import boto3
from botocore.exceptions import ClientError

# Redis 엔드포인트 및 TLS 설정
redis_host = 'master.my-project-valkey.ygzznw.use1.cache.amazonaws.com'
redis_port = 6379
redis_auth_token = 'YourStrongAuthPassword123!'  # Terraform으로 설정한 패스워드


# TLS를 활성화하여 Redis 클라이언트 생성
redis_client = redis.StrictRedis(
    host=redis_host,
    port=redis_port,
    ssl=True,  # TLS를 사용하여 연결
    password=redis_auth_token,  # AUTH 토큰 추가
    decode_responses=True
)

# DynamoDB 클라이언트 생성
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')  # DynamoDB의 리전 설정
table_name = 'my-dynamodb-table'
table = dynamodb.Table(table_name)

# 캐시의 TTL 설정 (초 단위)
CACHE_TTL = 60  # 60초 동안 캐시 데이터 유효

# 캐시 데이터 설정 (TTL 적용)
def set_cache_with_ttl(key, value):
    current_time = int(time.time())
    redis_client.set(key, value, ex=CACHE_TTL)  # 데이터와 TTL 설정
    redis_client.set(f"{key}:timestamp", current_time)  # 타임스탬프 저장

# Redis에서 키의 데이터와 타임스탬프를 검증
def get_cache_with_ttl(key):
    cached_value = redis_client.get(key)
    cached_timestamp = redis_client.get(f"{key}:timestamp")

    if cached_value and cached_timestamp:
        current_time = int(time.time())
        # 캐시가 유효한지 검증
        if current_time - int(cached_timestamp) < CACHE_TTL:
            print(f"Cache hit: {key} found in Redis and is fresh.")
            return cached_value
        else:
            print(f"Cache hit: {key} found in Redis but is stale.")
            # 캐시가 오래되었으므로 삭제
            redis_client.delete(key)
            redis_client.delete(f"{key}:timestamp")
    return None

# RDS에서 데이터를 조회하고 Redis에 캐시
def get_data(key):
    # 1. Redis에서 데이터 조회 (캐시 확인)
    value = get_cache_with_ttl(key)
    if value:
        return value

    # 2. 캐시가 없거나 오래되었으면 RDS 조회
    try:
        response = table.get_item(
            Key={'id': key}
        )
        if 'Item' in response:
            item = response['Item']
            # RDS에서 조회한 데이터를 Redis에 캐시
            set_cache_with_ttl(key, item['data'])
            print(f"{key} found in DynamoDB and cached in Redis.")
            return item['data']
        else:
            print(f"No item found in DynamoDB with id: {key}")
            return None
    except ClientError as e:
        print(f"Failed to connect to DynamoDB: {e}")
        return None

# 데이터 수정 시 RDS와 Redis 모두 업데이트
def update_data(key, value):
    # 1. RDS에 데이터 업데이트
    try:
        table.put_item(
            Item={
                'id': key,
                'data': value
            }
        )
        print(f"Data updated in DynamoDB with id: {key}")
        
        # 2. Redis 캐시 업데이트
        set_cache_with_ttl(key, value)
        print(f"Data updated in Redis cache with key: {key}")
    except Exception as e:
        print(f"Failed to update data in DynamoDB or cache in Redis: {e}")

# 시드 데이터 추가
def seed_data():
    # 초기 데이터를 위한 키-값 쌍
    seed_items = [
        {'id': '1', 'data': 'Initial data 1'},
        {'id': '2', 'data': 'Initial data 2'},
        {'id': '3', 'data': 'Initial data 3'},
        {'id': '123', 'data': 'Hello, DynamoDB!'}  # 이전 예제에서 조회한 키 포함
    ]
    
    try:
        for item in seed_items:
            table.put_item(Item=item)
        print(f"Seed data successfully added to DynamoDB table: {table_name}")
    except ClientError as e:
        print(f"Failed to seed data to DynamoDB: {e}")

# 프로그램 시작 시 DynamoDB에 시드 데이터 추가
seed_data()

# 예제 시나리오 실행
key = '123'
new_value = 'Hello, Updated Data!'

# 1. 데이터 조회 (최초 조회 시 캐시 미스, RDS에서 가져와 캐시 저장)
retrieved_value = get_data(key)
print(f"Retrieved value: {retrieved_value}")

# 2. 데이터 수정 (RDS 및 Redis 캐시 동기화)
update_data(key, new_value)

# 3. 수정 후 데이터 재조회 (Redis 캐시 사용)
retrieved_value_after_update = get_data(key)
print(f"Retrieved value after update: {retrieved_value_after_update}")
