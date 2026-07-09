variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Short project name used in resource naming"
  type        = string
  default     = "Test"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "staging"
}

variable "vpc_id" {
  description = "VPC ID to deploy resources into"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the ASG (single subnet since this is a single-instance staging setup)"
  type        = string
}

variable "availability_zone" {
  description = "AZ that the subnet above lives in (EBS volumes are AZ-locked)"
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into the instance"
  type        = string
  default     = "0.0.0.0/0" # tighten this to your office/VPN IP in production
}

# ---------------------------------------------------------------------------
# Instance type fallback chain
# ---------------------------------------------------------------------------
variable "instance_types" {
  description = <<-EOT
    Ordered list of instance types to try, most preferred first.
    Used as the override list in the ASG's mixed_instances_policy.
    If the first type has no spot capacity, AWS falls through to the next.
  EOT
  type        = list(string)
  default     = ["t3.medium", "t3.small", "t3.micro"]
}

# ---------------------------------------------------------------------------
# EBS
# ---------------------------------------------------------------------------
variable "ebs_volume_size" {
  description = "Size of the persistent data volume in GB"
  type        = number
  default     = 20
}

variable "ebs_volume_type" {
  description = "EBS volume type"
  type        = string
  default     = "gp3"
}

variable "ebs_device_name" {
  description = "Device name the volume attaches as"
  type        = string
  default     = "/dev/xvdf"
}

variable "ebs_mount_point" {
  description = "Mount point on the instance"
  type        = string
  default     = "/mnt/staging-data"
}

# ---------------------------------------------------------------------------
# Scheduling (native ASG scheduled actions — these DO support time_zone)
# ---------------------------------------------------------------------------
variable "timezone" {
  description = "IANA timezone for the ASG scheduled actions"
  type        = string
  default     = "Asia/Kathmandu"
}

variable "schedule_start_cron" {
  description = "Recurrence for scaling up, in the timezone above (Mon-Fri 10:00am NPT)"
  type        = string
  default     = "0 10 * * MON-FRI"
}

variable "schedule_stop_cron" {
  description = "Recurrence for scaling down, in the timezone above (Mon-Fri 5:00pm NPT)"
  type        = string
  default     = "0 17 * * MON-FRI"
}

# ---------------------------------------------------------------------------
# Holiday-check Lambda
# ---------------------------------------------------------------------------
variable "holiday_check_cron" {
  description = <<-EOT
    EventBridge (CloudWatch Events) cron expression, ALWAYS in UTC — classic
    EventBridge rules do not support a time_zone argument the way ASG
    scheduled actions do. Default below = 10:05am NPT converted to UTC
    (NPT is UTC+5:45, so 10:05am - 5:45 = 4:20am UTC).
  EOT
  type        = string
  default     = "20 4 ? * MON-FRI *"
}

variable "google_calendar_id" {
  description = "Google Calendar ID used for the holiday check"
  type        = string
}

variable "google_creds_secret_name" {
  description = "Secrets Manager secret name holding the Google service account JSON"
  type        = string
}

# ---------------------------------------------------------------------------
# Slack /staging-stop and /staging-start
# ---------------------------------------------------------------------------
variable "slack_signing_secret_name" {
  description = "Secrets Manager secret name holding the Slack app's signing secret (plain string, not JSON)"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project     = "staging"
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Cloudflare
# ---------------------------------------------------------------------------
variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID"
  type        = string
}

variable "cloudflare_domain_name" {
  description = "DNS record that should be updated"
  type        = string
}

variable "cloudflare_zone_name" {
  description = "Cloudflare zone name"
  type        = string
}

variable "cloudflare_token_secret_name" {
  description = "Secrets Manager secret containing the Cloudflare API token"
  type        = string
}
