output "asg_name" {
  description = "Name of the staging Auto Scaling Group"
  value       = aws_autoscaling_group.staging.name
}

output "asg_arn" {
  description = "ARN of the staging Auto Scaling Group"
  value       = aws_autoscaling_group.staging.arn
}

output "instance_type_fallback_order" {
  description = "Priority order the ASG will try instance types in"
  value       = var.instance_types
}

output "launch_template_id" {
  description = "Launch template ID used by the ASG"
  value       = aws_launch_template.staging.id
}

output "ebs_volume_id" {
  description = "Persistent data volume ID — same volume reattaches on every instance replacement"
  value       = aws_ebs_volume.staging_data.id
}

output "security_group_id" {
  description = "Security group ID (22 / 80 / 443 only)"
  value       = aws_security_group.staging.id
}

output "holiday_lambda_function_name" {
  description = "Name of the single holiday-check Lambda"
  value       = aws_lambda_function.holiday_check.function_name
}

output "holiday_check_schedule_utc" {
  description = "Reminder: this cron is UTC, not NPT — see variables.tf comment"
  value       = var.holiday_check_cron
}

output "scale_up_schedule" {
  value = "${var.schedule_start_cron} (${var.timezone})"
}

output "scale_down_schedule" {
  value = "${var.schedule_stop_cron} (${var.timezone})"
}

output "ebs_reattach_lambda_function_name" {
  description = "Name of the lifecycle-hook-triggered EBS reattach Lambda"
  value       = aws_lambda_function.ebs_reattach.function_name
}

output "slack_commands_endpoint" {
  description = "Register this URL + /slack/commands as the Request URL for both Slack slash commands"
  value       = "${aws_apigatewayv2_api.slack.api_endpoint}/slack/commands"
}
