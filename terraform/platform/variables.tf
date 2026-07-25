variable "aws_region" {
  description = "AWS region used by the shared platform."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = length(trimspace(var.aws_region)) > 0
    error_message = "aws_region must be provided."
  }
}

variable "instance_profile_name" {
  description = "Name of the pre-existing EC2 instance profile attached to the K3s node. IAM roles are external and provided by configuration; this stack never creates or modifies IAM resources."
  type        = string

  validation {
    condition     = length(trimspace(var.instance_profile_name)) > 0
    error_message = "instance_profile_name must be provided."
  }

  validation {
    condition     = !can(regex("^arn:", var.instance_profile_name))
    error_message = "instance_profile_name must be the profile name, not an ARN."
  }
}

variable "k3s_instance_type" {
  description = "EC2 instance type for the K3s node."
  type        = string
  default     = "t3.medium"

  validation {
    condition     = can(regex("^[a-z0-9]+\\.[a-z0-9]+$", var.k3s_instance_type))
    error_message = "k3s_instance_type must be a valid EC2 instance type."
  }
}

# Sem default por decisao: um default seria uma segunda fonte silenciosa da
# versao, usada por qualquer execucao fora do workflow. A fonte unica e
# config/official.yml, exportada como TF_VAR_k3s_version.
variable "k3s_version" {
  description = "K3s version, read from config/official.yml and exported as TF_VAR_k3s_version."
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version must follow the vX.Y.Z+k3sN format."
  }
}

variable "k3s_root_volume_size" {
  description = "Root EBS volume size, in GiB, for the K3s node."
  type        = number
  default     = 30

  validation {
    condition     = var.k3s_root_volume_size >= 20 && var.k3s_root_volume_size <= 100
    error_message = "k3s_root_volume_size must be between 20 and 100 GiB."
  }
}
