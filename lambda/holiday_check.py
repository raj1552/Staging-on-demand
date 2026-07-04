import os
import boto3
from datetime import datetime, timedelta
from google.oauth2 import service_account
from googleapiclient.discovery import build

asg_client = boto3.client('autoscaling')
secrets_client = boto3.client('secretsmanager')

ASG_NAME = os.environ['ASG_NAME']
CALENDAR_ID = os.environ['CALENDAR_ID']
GOOGLE_CREDS_SECRET_NAME = os.environ['GOOGLE_CREDS_SECRET_NAME']


def get_calendar_service():
    secret = secrets_client.get_secret_value(SecretId=GOOGLE_CREDS_SECRET_NAME)
    creds_info = eval(secret['SecretString'])  # or json.loads if stored as JSON
    creds = service_account.Credentials.from_service_account_info(
        creds_info,
        scopes=['https://www.googleapis.com/auth/calendar.readonly']
    )
    return build('calendar', 'v3', credentials=creds)


def is_holiday_today():
    service = get_calendar_service()

    # Lambda runs in UTC; localize the date window to Nepal time (UTC+5:45)
    now_utc = datetime.utcnow()
    nepal_offset = timedelta(hours=5, minutes=45)
    now_npt = now_utc + nepal_offset

    day_start = now_npt.replace(hour=0, minute=0, second=0, microsecond=0) - nepal_offset
    day_end = day_start + timedelta(days=1)

    events_result = service.events().list(
        calendarId=CALENDAR_ID,
        timeMin=day_start.isoformat() + 'Z',
        timeMax=day_end.isoformat() + 'Z',
        singleEvents=True
    ).execute()

    events = events_result.get('items', [])
    return any('holiday' in e.get('summary', '').lower() for e in events)


def force_asg_down():
    asg_client.update_auto_scaling_group(
        AutoScalingGroupName=ASG_NAME,
        MinSize=0,
        DesiredCapacity=0,
        MaxSize=0
    )


def lambda_handler(event, context):
    if is_holiday_today():
        force_asg_down()
        return {'statusCode': 200, 'body': 'Holiday detected — ASG forced down'}

    return {'statusCode': 200, 'body': 'Working day — no override needed'}
