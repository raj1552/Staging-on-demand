# ---------------------------------------------------------------------------
# ASG lifecycle hook — pauses new instances in "Pending:Wait" until the
# ebs_reattach Lambda below confirms the volume is attached, so the
# instance never goes InService without its persistent data.
# ---------------------------------------------------------------------------
resource "aws_autoscaling_lifecycle_hook" "ebs_attach" {
  name                   = "${var.project_name}-${var.environment}-ebs-attach"
  autoscaling_group_name = aws_autoscaling_group.staging.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
  heartbeat_timeout      = 300       # 5 min — plenty for an attach-volume call
  default_result         = "ABANDON" # fail closed: no cert data, no traffic
}

# ---------------------------------------------------------------------------
# EBS reattach Lambda
# ---------------------------------------------------------------------------
data "archive_file" "ebs_reattach_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/ebs_reattach.py"
  output_path = "${path.module}/lambda/ebs_reattach.zip"
}

resource "aws_iam_role" "ebs_reattach_lambda" {
  name = "${var.project_name}-${var.environment}-ebs-reattach-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ebs_reattach_lambda_policy" {
  name = "ebs-reattach-policy"
  role = aws_iam_role.ebs_reattach_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:DescribeVolumes",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      },

      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:${var.cloudflare_token_secret_name}*"
      },

      {
        Effect = "Allow"
        Action = [
          "autoscaling:CompleteLifecycleAction"
        ]
        Resource = aws_autoscaling_group.staging.arn
      },

      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-${var.environment}-ebs-reattach*"
      }
    ]
  })
}

resource "aws_lambda_function" "ebs_reattach" {
  function_name    = "${var.project_name}-${var.environment}-ebs-reattach"
  filename         = data.archive_file.ebs_reattach_lambda.output_path
  source_code_hash = data.archive_file.ebs_reattach_lambda.output_base64sha256
  handler          = "ebs_reattach.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.ebs_reattach_lambda.arn
  timeout          = 120

  environment {
  variables = {
    EBS_VOLUME_ID = aws_ebs_volume.staging_data.id
    DEVICE_NAME   = var.ebs_device_name

    DOMAIN_NAME                  = var.cloudflare_domain_name
    CLOUDFLARE_ZONE_NAME         = var.cloudflare_zone_name
    CLOUDFLARE_ZONE_ID           = var.cloudflare_zone_id
    CLOUDFLARE_TOKEN_SECRET_NAME = var.cloudflare_token_secret_name
  }
}

  tags = var.tags
}

# ASG lifecycle events publish to the default EventBridge bus automatically —
# no SNS topic needed, just a rule matching the event and a direct Lambda target.
resource "aws_cloudwatch_event_rule" "asg_lifecycle_launch" {
  name        = "${var.project_name}-${var.environment}-asg-launch"
  description = "Fires when the ASG lifecycle hook pauses a new instance for EBS attach"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance-launch Lifecycle Action"]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.staging.name]
    }
  })
}

resource "aws_cloudwatch_event_target" "asg_lifecycle_launch" {
  rule = aws_cloudwatch_event_rule.asg_lifecycle_launch.name
  arn  = aws_lambda_function.ebs_reattach.arn
}

resource "aws_lambda_permission" "allow_eventbridge_lifecycle" {
  statement_id  = "AllowEventBridgeInvokeLifecycle"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ebs_reattach.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.asg_lifecycle_launch.arn
}
