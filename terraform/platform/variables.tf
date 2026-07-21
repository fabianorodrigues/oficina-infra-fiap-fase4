variable "aws_region" {
  description = "AWS region used by the shared platform."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = length(trimspace(var.aws_region)) > 0
    error_message = "aws_region must be provided."
  }
}

variable "cluster_enabled_log_types" {
  description = "EKS control plane log types enabled for the cluster."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "load_balancer_controller_chart_version" {
  description = "Chart version for AWS Load Balancer Controller. Keep aligned with the IAM policy embedded in iam.tf."
  type        = string
  default     = "3.4.1"
}

variable "secrets_store_csi_driver_chart_version" {
  description = "Optional chart version for Secrets Store CSI Driver."
  type        = string
  default     = ""
}

variable "ascp_chart_version" {
  description = "Optional chart version for AWS Secrets and Configuration Provider."
  type        = string
  default     = ""
}

variable "opentelemetry_collector_chart_version" {
  description = "Optional chart version for OpenTelemetry Collector."
  type        = string
  default     = ""
}

variable "newrelic_chart_version" {
  description = "Optional chart version for the New Relic Kubernetes integration."
  type        = string
  default     = ""
}

variable "platform_iam_roles" {
  description = "Optional existing IAM role ARNs for accounts where selected platform roles are provided outside Terraform."
  type = object({
    eks_cluster_role_arn              = optional(string, "")
    eks_node_group_role_arn           = optional(string, "")
    load_balancer_controller_role_arn = optional(string, "")
    workload_role_arn                 = optional(string, "")
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for arn in [
        var.platform_iam_roles.eks_cluster_role_arn,
        var.platform_iam_roles.eks_node_group_role_arn,
        var.platform_iam_roles.load_balancer_controller_role_arn,
        var.platform_iam_roles.workload_role_arn
      ] : can(regex("^arn:[^:]+:iam::[0-9]{12}:role/.+$", trimspace(arn))) if trimspace(arn) != ""
    ])
    error_message = "Each configured platform IAM role must be a valid IAM role ARN."
  }
}
