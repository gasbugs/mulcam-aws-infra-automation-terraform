import boto3
from boto3.dynamodb.conditions import Key
import datetime

# AWS DynamoDB 리소스 생성
dynamodb = boto3.resource('dynamodb')

# DynamoDB 테이블 이름 (main.tf에서 설정한 이름과 동일해야 함)
table_name = 'Users'

# 테이블 객체 생성
table = dynamodb.Table(table_name)

def put_item(user_id, name, email):
    """
    DynamoDB 테이블에 사용자 정보를 추가하는 함수
    """
    try:
        current_time = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        response = table.put_item(
            Item={
                'UserId': user_id,
                'Name': name,
                'Email': email,
                'CreatedAt': current_time
            }
        )
        print(f"PutItem succeeded: {response}")
    except Exception as e:
        print(f"Error adding item to table: {e}")

def query_items(user_id):
    """
    DynamoDB 테이블에서 UserId로 사용자 정보를 검색하는 함수
    """
    try:
        response = table.query(
            KeyConditionExpression=Key('UserId').eq(user_id)
        )
        items = response.get('Items', [])
        if items:
            return items
        else:
            print(f"No items found with UserId: {user_id}")
            return []
    except Exception as e:
        print(f"Error querying items from table: {e}")
        return []

def main():
    # 데이터 쓰기 예제
    put_item('user1', 'John Doe', 'john.doe@example.com')
    put_item('user2', 'Jane Doe', 'jane.doe@example.com')

    # 데이터 읽기 예제
    users = query_items('user1')
    for user in users:
        print(f"Retrieved user: {user}")

if __name__ == "__main__":
    main()