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
  default     = ["api", "audit", "authenticator"]
}

variable "load_balancer_controller_chart_version" {
  description = "Optional chart version for AWS Load Balancer Controller. Leave empty to use the chart repository default."
  type        = string
  default     = ""
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
