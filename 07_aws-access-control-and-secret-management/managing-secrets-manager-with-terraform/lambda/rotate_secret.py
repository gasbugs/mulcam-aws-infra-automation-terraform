import boto3
import os
import string
import random
import json

secretsmanager_client = boto3.client('secretsmanager')

def lambda_handler(event, context):
    secret_id = os.environ['SECRET_ID']
    
    # 새로운 비밀정보 생성 (랜덤 패스워드)
    new_password = generate_random_password()

    # AWS Secrets Manager에 새 비밀정보 저장
    secret_string = {"password":new_password,"username":"admin"}

    secretsmanager_client.put_secret_value(
        SecretId=secret_id,
        SecretString=json.dumps(secret_string)
    )

    print(f"Successfully rotated secret for {secret_id}")

def generate_random_password():
    # 랜덤한 비밀정보(비밀번호) 생성
    characters = string.ascii_letters + string.digits + string.punctuation
    password = ''.join(random.choice(characters) for i in range(16))
    return password
