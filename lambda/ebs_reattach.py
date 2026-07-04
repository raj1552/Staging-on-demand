import boto3

ec2_client = boto3.client('ec2')
asg_client = boto3.client('autoscaling')


def lambda_handler(event, context):
    detail = event['detail']
    instance_id = detail['EC2InstanceId']
    lifecycle_hook_name = detail['LifecycleHookName']
    asg_name = detail['AutoScalingGroupName']

    import os
    volume_id = os.environ['EBS_VOLUME_ID']
    device_name = os.environ['DEVICE_NAME']

    try:
        waiter = ec2_client.get_waiter('instance_running')
        waiter.wait(InstanceIds=[instance_id])

        # If the volume is still attached to a previous (terminated) instance,
        # detach it first — spot replacements often leave it dangling briefly.
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

        asg_client.complete_lifecycle_action(
            LifecycleHookName=lifecycle_hook_name,
            AutoScalingGroupName=asg_name,
            InstanceId=instance_id,
            LifecycleActionResult='CONTINUE'
        )

    except Exception as e:
        # Abandon on failure — ASG will terminate this instance and launch
        # a replacement, which gets another shot at attaching the volume.
        asg_client.complete_lifecycle_action(
            LifecycleHookName=lifecycle_hook_name,
            AutoScalingGroupName=asg_name,
            InstanceId=instance_id,
            LifecycleActionResult='ABANDON'
        )
        raise e
