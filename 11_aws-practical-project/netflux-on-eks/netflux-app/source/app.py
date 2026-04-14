from flask import Flask, render_template, url_for
import boto3
import logging
from botocore.exceptions import ClientError
from botocore.exceptions import NoCredentialsError
import os

app = Flask(__name__, static_folder='static')

# 로깅 설정
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# 환경 변수에서 DynamoDB 설정 가져오기
DYNAMODB_TABLE = os.environ.get('DYNAMODB_TABLE', 'Movies')
AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')

# 기존 영화 데이터
default_movies = [
    {
        "title": "모아나 2",
        "year": 2025,
        "poster": "static/moana2_poster.jpg",
        "description": "디즈니의 인기 애니메이션 '모아나'의 속편"
    },
    {
        "title": "소닉 3",
        "year": 2025,
        "poster": "static/sonic3_poster.jpg",
        "description": "빠른 고슴도치 소닉의 새로운 모험"
    },
    {
        "title": "캡틴 아메리카: 브레이브 뉴 월드",
        "year": 2025,
        "poster": "static/captain_america_poster.jpg",
        "description": "앤서니 매키 주연의 새로운 캡틴 아메리카 영화"
    },
    {
        "title": "위키드: 파트 2",
        "year": 2025,
        "poster": "static/wicked2_poster.jpg",
        "description": "아리아나 그란데와 신시아 에리보 주연의 뮤지컬 영화"
    }
]

def get_or_create_movies_in_dynamodb():
    try:
        dynamodb = boto3.resource('dynamodb', region_name=AWS_REGION)
        table = dynamodb.Table(DYNAMODB_TABLE)
        
        # DynamoDB에서 데이터 가져오기
        response = table.scan()
        movies = response.get('Items', [])
        
        if not movies:
            logger.info("DynamoDB에 데이터가 없습니다. 기본 데이터를 추가합니다.")
            with table.batch_writer() as batch:
                for movie in default_movies:
                    # 키 속성 확인 및 데이터 유형 변환
                    if 'title' not in movie:
                        logger.error(f"키 속성 'title'이 없는 항목: {movie}")
                        continue
                    if 'year' in movie:
                        movie['year'] = int(movie['year'])
                    batch.put_item(Item=movie)
            logger.info("기본 데이터가 DynamoDB에 추가되었습니다.")
            return default_movies
        else:
            logger.info("DynamoDB에서 영화 데이터를 성공적으로 가져왔습니다.")
            return movies
    except ClientError as e:
        logger.error(f"DynamoDB 접근 오류: {e}")
        return default_movies



@app.route('/')
def index():
    movies = get_or_create_movies_in_dynamodb()
    return render_template('index.html', movies=movies)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')
