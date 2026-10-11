variable "aws_profile" {
  description = "AWS CLI profile to use. Must provide short-lived credentials (aws login or SSO), not long-lived access keys."
  type        = string
}

variable "aws_region" {
  description = "Region to deploy into."
  type        = string
  default     = "us-west-2"
}

variable "name" {
  description = "Prefix for resource names."
  type        = string
  default     = "qtailscale-ec2"
}

variable "shortcut_token_parameter_name" {
  description = "Name of the SSM SecureString parameter holding the shortcut token. The value is created outside Terraform."
  type        = string
  default     = "/qtailscale-ec2/shortcut-token"

  validation {
    condition     = startswith(var.shortcut_token_parameter_name, "/")
    error_message = "The parameter name must start with a slash."
  }
}

variable "tailscale_authkey_parameter_name" {
  description = "Name of the SSM SecureString parameter holding the Tailscale auth key. The value is created outside Terraform."
  type        = string
  default     = "/qtailscale-ec2/tailscale-authkey"

  validation {
    condition     = startswith(var.tailscale_authkey_parameter_name, "/")
    error_message = "The parameter name must start with a slash."
  }
}

variable "tailscale_tag" {
  description = "Tailscale tag applied to the exit node."
  type        = string
  default     = "tag:exit-us"

  validation {
    condition     = startswith(var.tailscale_tag, "tag:")
    error_message = "The tag must start with \"tag:\"."
  }
}

variable "tailscale_hostname" {
  description = "Hostname shown in the tailnet."
  type        = string
  default     = "exit-us"
}

variable "auto_stop_minutes" {
  description = "Minutes after each boot until the instance shuts itself down."
  type        = number
  default     = 75

  validation {
    condition     = var.auto_stop_minutes >= 5 && var.auto_stop_minutes <= 720
    error_message = "Must be between 5 and 720."
  }
}

variable "lambda_reserved_concurrency" {
  description = "Reserved concurrency for the Lambda function (1 or 2). Use -1 (unreserved) only while the account concurrency limit is too low to reserve any."
  type        = number
  default     = 1

  validation {
    condition     = contains([-1, 1, 2], var.lambda_reserved_concurrency)
    error_message = "Must be 1, 2, or -1 (unreserved)."
  }
}

variable "log_retention_days" {
  description = "Retention of the Lambda log group, in days."
  type        = number
  default     = 14
}

variable "vpc_cidr" {
  description = "CIDR of the dedicated VPC. The single subnet uses the same range."
  type        = string
  default     = "10.99.0.0/24"
}
