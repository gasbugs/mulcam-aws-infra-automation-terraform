def handler(event, context):
    print("log test!")
    return {
        'statusCode': 200,
        'body': 'Hello, World!'
    }