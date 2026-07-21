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
    from the internal ALB. Auto-detection excludes the shared backend security
    group (tagged elbv2.k8s.aws/resource=backend-sg) created by the AWS Load
    Balancer Controller and requires exactly one remaining frontend security
    group; otherwise the plan fails and this value must be provided explicitly.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.alb_frontend_security_group_id == "" || can(regex("^sg-[0-9a-f]{8,}$", var.alb_frontend_security_group_id))
    error_message = "alb_frontend_security_group_id must be empty or a valid 'sg-' identifier."
  }
}
