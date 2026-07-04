import json
import hashlib
import hmac
import time
import os
import boto3
from urllib.parse import parse_qs

asg_client = boto3.client('autoscaling')
secrets_client = boto3.client('secretsmanager')

ASG_NAME = os.environ['ASG_NAME']
SLACK_SIGNING_SECRET_NAME = os.environ['SLACK_SIGNING_SECRET_NAME']

def get_signing_secret():
    secret = secrets_client.get_secret_value(SecretId=SLACK_SIGNING_SECRET_NAME)
    return secret['SecretString']


def verify_slack_signature(headers, body):
    signing_secret = get_signing_secret()
    timestamp = headers.get('x-slack-request-timestamp', '0')

    if abs(time.time() - int(timestamp)) > 60 * 5:
        return False  # replay attack protection

    sig_basestring = f"v0:{timestamp}:{body}"
    my_signature = 'v0=' + hmac.new(
        signing_secret.encode(),
        sig_basestring.encode(),
        hashlib.sha256
    ).hexdigest()

    slack_signature = headers.get('x-slack-signature', '')
    return hmac.compare_digest(my_signature, slack_signature)


def lambda_handler(event, context):
    # API Gateway HTTP API (v2) lowercases header keys
    headers = event.get('headers', {})
    body = event.get('body', '')

    if event.get('isBase64Encoded'):
        import base64
        body = base64.b64decode(body).decode('utf-8')

    if not verify_slack_signature(headers, body):
        return {'statusCode': 401, 'body': 'Invalid signature'}

    params = parse_qs(body)
    command = params.get('command', [''])[0]
    user_name = params.get('user_name', ['someone'])[0]

    if command == '/staging-stop':
        asg_client.update_auto_scaling_group(
            AutoScalingGroupName=ASG_NAME,
            MinSize=0, DesiredCapacity=0, MaxSize=0
        )
        text = (f':white_check_mark: Staging stopped by {user_name}. '
                f'It will auto-start tomorrow at 10am (unless it\'s a holiday).')

    elif command == '/staging-start':
        asg_client.update_auto_scaling_group(
            AutoScalingGroupName=ASG_NAME,
            MinSize=1, DesiredCapacity=1, MaxSize=1
        )
        text = f':rocket: Staging started by {user_name}.'

    else:
        return {'statusCode': 200, 'body': 'Unknown command'}

    return {
        'statusCode': 200,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps({'response_type': 'in_channel', 'text': text})
    }