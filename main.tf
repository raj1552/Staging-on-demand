terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# AMI
# ---------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
resource "aws_security_group" "staging" {
  name        = "${var.project_name}-${var.environment}-sg"
  description = "Staging instance - SSH, HTTP, HTTPS only (app port stays behind Nginx)"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.project_name}-${var.environment}-sg" })
}

# ---------------------------------------------------------------------------
# Persistent EBS volume (survives every spot interruption / replacement)
# ---------------------------------------------------------------------------
resource "aws_ebs_volume" "staging_data" {
  availability_zone = var.availability_zone
  size              = var.ebs_volume_size
  type              = var.ebs_volume_type

  tags = merge(var.tags, { Name = "${var.project_name}-${var.environment}-data" })
}

# ---------------------------------------------------------------------------
# IAM — instance role
# ---------------------------------------------------------------------------
# No EBS permissions needed here anymore: attach/detach is handled by the
# ebs_reattach Lambda (see lifecycle.tf), triggered by the ASG lifecycle
# hook. This role/profile exists as an attachment point for the instance
# in case you add CloudWatch agent, SSM, etc. later.
resource "aws_iam_role" "staging_instance" {
  name = "${var.project_name}-${var.environment}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_instance_profile" "staging" {
  name = "${var.project_name}-${var.environment}-profile"
  role = aws_iam_role.staging_instance.name
}

# ---------------------------------------------------------------------------
# Launch template
# ---------------------------------------------------------------------------
resource "aws_launch_template" "staging" {
  name_prefix   = "${var.project_name}-${var.environment}-"
  image_id      = data.aws_ami.ubuntu.id
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.staging.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.staging.name
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    ebs_volume_id = aws_ebs_volume.staging_data.id
    device_name   = var.ebs_device_name
    mount_point   = var.ebs_mount_point
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.project_name}-${var.environment}" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Auto Scaling Group — mixed instances policy for the type fallback chain
# ---------------------------------------------------------------------------
resource "aws_autoscaling_group" "staging" {
  name                = "${var.project_name}-${var.environment}-asg"
  vpc_zone_identifier = [var.subnet_id]

  # Base state is "off" — the scheduled action below turns it on
  min_size         = 0
  max_size         = 1
  desired_capacity = 0

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.staging.id
        version             = "$Latest"
      }

      # Ordered fallback: try instance_types[0] first, fall through on
      # capacity shortage. capacity-optimized-prioritized (below) respects
      # this order as a priority hint while still favoring available pools.
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }

    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0 # fully spot
      spot_allocation_strategy                 = "capacity-optimized-prioritized"
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Native scheduled actions — routine daily on/off, timezone-aware
# ---------------------------------------------------------------------------
resource "aws_autoscaling_schedule" "scale_up" {
  scheduled_action_name  = "${var.project_name}-${var.environment}-scale-up"
  autoscaling_group_name = aws_autoscaling_group.staging.name
  recurrence              = var.schedule_start_cron
  time_zone               = var.timezone
  min_size                = 1
  max_size                = 1
  desired_capacity        = 1
}

resource "aws_autoscaling_schedule" "scale_down" {
  scheduled_action_name  = "${var.project_name}-${var.environment}-scale-down"
  autoscaling_group_name = aws_autoscaling_group.staging.name
  recurrence              = var.schedule_stop_cron
  time_zone               = var.timezone
  min_size                = 0
  max_size                = 0
  desired_capacity        = 0
}

# ---------------------------------------------------------------------------
# Holiday-check Lambda — the one Lambda in this whole setup
# ---------------------------------------------------------------------------
data "archive_file" "holiday_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/holiday_check.py"
  output_path = "${path.module}/lambda/holiday_check.zip"
}

resource "aws_iam_role" "holiday_lambda" {
  name = "${var.project_name}-${var.environment}-holiday-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "holiday_lambda_policy" {
  name = "holiday-lambda-policy"
  role = aws_iam_role.holiday_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["autoscaling:UpdateAutoScalingGroup"]
        Resource = aws_autoscaling_group.staging.arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:*:secret:${var.google_creds_secret_name}*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-${var.environment}-holiday-check*"
      }
    ]
  })
}

resource "aws_lambda_function" "holiday_check" {
  function_name    = "${var.project_name}-${var.environment}-holiday-check"
  filename         = data.archive_file.holiday_lambda.output_path
  source_code_hash = data.archive_file.holiday_lambda.output_base64sha256
  handler          = "holiday_check.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.holiday_lambda.arn
  timeout          = 30

  environment {
    variables = {
      ASG_NAME                 = aws_autoscaling_group.staging.name
      CALENDAR_ID               = var.google_calendar_id
      GOOGLE_CREDS_SECRET_NAME  = var.google_creds_secret_name
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "holiday_check" {
  name                = "${var.project_name}-${var.environment}-holiday-check"
  description         = "Fires every weekday; Lambda decides internally whether today is a holiday"
  schedule_expression = "cron(${var.holiday_check_cron})"
}

resource "aws_cloudwatch_event_target" "holiday_check" {
  rule = aws_cloudwatch_event_rule.holiday_check.name
  arn  = aws_lambda_function.holiday_check.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.holiday_check.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.holiday_check.arn
}
