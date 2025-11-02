import boto3
from boto3.dynamodb.conditions import Key

# AWS DynamoDB 리소스 생성
dynamodb = boto3.resource('dynamodb')

# DynamoDB 테이블 이름 (main.tf에서 설정한 이름과 동일해야 함)
table_name = 'Users'

# 테이블 객체 생성
table = dynamodb.Table(table_name)

def put_item(user_id, created_at, name, username):
    """
    DynamoDB 테이블에 데이터 추가
    """
    try:
        response = table.put_item(
            Item={
                'UserId': user_id,
                'CreatedAt': created_at,
                'Name': name,
                'Username': username
            }
        )
        print(f"PutItem succeeded: {response}")
    except Exception as e:
        print(f"Error adding item to table: {e}")

def get_item_by_user_id_and_range_key(user_id, start_date, end_date):
    """
    해시 키(UserId)와 정렬 키(CreatedAt)로 데이터 조회
    특정 사용자(UserId)의 데이터를 시간 범위로 조회
    """
    try:
        response = table.query(
            KeyConditionExpression=Key('UserId').eq(user_id) & Key('CreatedAt').between(start_date, end_date)
        )
        return response.get('Items', [])
    except Exception as e:
        print(f"Error retrieving items by UserId and CreatedAt: {e}")

def get_item_by_username(username):
    """
    글로벌 보조 인덱스(GSI)로 데이터 조회
    Username을 사용해 GSI로 데이터 조회
    """
    try:
        response = table.query(
            IndexName='UsernameIndex',
            KeyConditionExpression=Key('Username').eq(username)
        )
        return response.get('Items', [])
    except Exception as e:
        print(f"Error retrieving items by Username GSI: {e}")

def update_item(user_id, created_at, new_name):
    """
    항목 업데이트
    특정 UserId와 CreatedAt을 가진 항목의 Name 속성 업데이트
    """
    try:
        response = table.update_item(
            Key={
                'UserId': user_id,
                'CreatedAt': created_at
            },
            UpdateExpression="set #name = :new_name",
            ExpressionAttributeNames={
                '#name': 'Name'
            },
            ExpressionAttributeValues={
                ':new_name': new_name
            }
        )
        print(f"UpdateItem succeeded: {response}")
    except Exception as e:
        print(f"Error updating item: {e}")

def delete_item(user_id, created_at):
    """
    특정 항목 삭제
    UserId와 CreatedAt으로 항목 식별하여 삭제
    """
    try:
        response = table.delete_item(
            Key={
                'UserId': user_id,
                'CreatedAt': created_at
            }
        )
        print(f"DeleteItem succeeded: {response}")
    except Exception as e:
        print(f"Error deleting item: {e}")

def main():
    # 예시 데이터 생성 (쓰기)
    put_item('user1', '2024-06-01T00:00:00', 'John Doe', 'johndoe')
    put_item('user1', '2024-07-01T00:00:00', 'Jane Smith', 'janesmith')

    # 1. 특정 사용자(UserId)의 시간 범위 내 데이터 조회 (Range Key 활용)
    print("Getting items by UserId and CreatedAt range:")
    items = get_item_by_user_id_and_range_key('user1', '2024-01-01', '2024-12-31')
    print(items)

    # 2. 글로벌 보조 인덱스(GSI)를 사용하여 Username으로 데이터 조회
    print("Getting items by Username (using GSI):")
    username_items = get_item_by_username('johndoe')
    print(username_items)

    # 3. 특정 항목의 Name 속성 업데이트
    print("Updating an item's Name:")
    update_item('user1', '2024-06-01T00:00:00', 'John Smith')

    # 업데이트 결과 확인
    updated_items = get_item_by_user_id_and_range_key('user1', '2024-01-01', '2024-12-31')
    print(updated_items)

    # 4. 특정 항목 삭제
    print("Deleting an item:")
    delete_item('user1', '2024-07-01T00:00:00')

    # 삭제 결과 확인
    remaining_items = get_item_by_user_id_and_range_key('user1', '2024-01-01', '2024-12-31')
    print(remaining_items)

if __name__ == "__main__":
    main()
