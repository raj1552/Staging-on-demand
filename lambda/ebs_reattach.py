import boto3
import os
import json
import urllib.request
import urllib.error

ec2_client = boto3.client('ec2')
asg_client = boto3.client('autoscaling')
secrets_client = boto3.client('secretsmanager')

DOMAIN_NAME = os.environ.get('DOMAIN_NAME')
CLOUDFLARE_ZONE_ID = os.environ.get('CLOUDFLARE_ZONE_ID')
CLOUDFLARE_TOKEN_SECRET_NAME = os.environ.get('CLOUDFLARE_TOKEN_SECRET_NAME')
CLOUDFLARE_ZONE_NAME = os.environ["CLOUDFLARE_ZONE_NAME"]

CF_API_BASE = "https://api.cloudflare.com/client/v4"


def cf_request(method, path, token, body=None):
    url = f"{CF_API_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())


def update_dns(instance_id):
    if not all([
        DOMAIN_NAME,
        CLOUDFLARE_ZONE_NAME,
        CLOUDFLARE_ZONE_ID,
        CLOUDFLARE_TOKEN_SECRET_NAME
    ]):
        return

    fqdn = f"{DOMAIN_NAME}.{CLOUDFLARE_ZONE_NAME}"

    instance = ec2_client.describe_instances(
        InstanceIds=[instance_id]
    )

    public_ip = instance["Reservations"][0]["Instances"][0].get("PublicIpAddress")

    if not public_ip:
        return

    secret = secrets_client.get_secret_value(
        SecretId=CLOUDFLARE_TOKEN_SECRET_NAME
    )
    token = secret["SecretString"]

    existing = cf_request(
        "GET",
        f"/zones/{CLOUDFLARE_ZONE_ID}/dns_records?type=A&name={fqdn}",
        token
    )

    record_body = {
        "type": "A",
        "name": fqdn,
        "content": public_ip,
        "ttl": 60,
        "proxied": False
    }

    records = existing.get("result", [])

    if records:
        # Update the first record
        cf_request(
            "PATCH",
            f"/zones/{CLOUDFLARE_ZONE_ID}/dns_records/{records[0]['id']}",
            token,
            record_body
        )

        # Delete duplicate records
        for record in records[1:]:
            cf_request(
                "DELETE",
                f"/zones/{CLOUDFLARE_ZONE_ID}/dns_records/{record['id']}",
                token
            )
    else:
        # Create the record if it doesn't exist
        cf_request(
            "POST",
            f"/zones/{CLOUDFLARE_ZONE_ID}/dns_records",
            token,
            record_body
        )


def lambda_handler(event, context):
    detail = event['detail']
    instance_id = detail['EC2InstanceId']
    lifecycle_hook_name = detail['LifecycleHookName']
    asg_name = detail['AutoScalingGroupName']

    volume_id = os.environ['EBS_VOLUME_ID']
    device_name = os.environ['DEVICE_NAME']

    try:
        waiter = ec2_client.get_waiter('instance_running')
        waiter.wait(InstanceIds=[instance_id])

        vol = ec2_client.describe_volumes(VolumeIds=[volume_id])['Volumes'][0]
        if vol['State'] == 'in-use':
            attached_instance = vol['Attachments'][0]['InstanceId']
            if attached_instance != instance_id:
                ec2_client.detach_volume(VolumeId=volume_id, Force=True)
                waiter = ec2_client.get_waiter('volume_available')
                waiter.wait(VolumeIds=[volume_id])

        ec2_client.attach_volume(
            VolumeId=volume_id,
            InstanceId=instance_id,
            Device=device_name
        )

        waiter = ec2_client.get_waiter('volume_in_use')
        waiter.wait(VolumeIds=[volume_id])

        # Point Cloudflare DNS at wherever this instance actually landed,
        # avoids ever needing an Elastic IP that would sit idle (and
        # billed) every night and on holidays
        update_dns(instance_id)

        asg_client.complete_lifecycle_action(
            LifecycleHookName=lifecycle_hook_name,
            AutoScalingGroupName=asg_name,
            InstanceId=instance_id,
            LifecycleActionResult='CONTINUE'
        )

    except Exception as e:
        asg_client.complete_lifecycle_action(
            LifecycleHookName=lifecycle_hook_name,
            AutoScalingGroupName=asg_name,
            InstanceId=instance_id,
            LifecycleActionResult='ABANDON'
        )
        raise e