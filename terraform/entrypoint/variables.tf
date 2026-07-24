variable "aws_region" {
  description = "AWS region that hosts the API Gateway HTTP API, the VPC Link and the internal ALB."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = length(trimspace(var.aws_region)) > 0
    error_message = "aws_region must be provided."
  }
}

variable "alb_frontend_security_group_id" {
  description = <<-EOT
    Optional explicit ALB frontend security group ID. Leave empty to auto-detect
    from the internal ALB. The platform stack manages exactly one security group
    for the internal ALB, so auto-detection reads the ALB's security groups and
    requires exactly one. If the data source ever returns more than one group the
    plan fails and this value must be provided explicitly.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.alb_frontend_security_group_id == "" || can(regex("^sg-[0-9a-f]{8,}$", var.alb_frontend_security_group_id))
    error_message = "alb_frontend_security_group_id must be empty or a valid 'sg-' identifier."
  }
}
