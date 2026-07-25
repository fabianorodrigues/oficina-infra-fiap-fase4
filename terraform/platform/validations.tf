check "official_platform_contract" {
  assert {
    condition     = local.project_name == "oficina"
    error_message = "config/official.yml project.name must be oficina."
  }

  assert {
    condition     = local.cluster_name == "oficina" && local.namespace == "oficina"
    error_message = "Kubernetes cluster name and namespace must be oficina."
  }

  assert {
    condition     = local.container_port == 8080 && local.official.kubernetes.replicas == 1
    error_message = "Kubernetes baseline must be container port 8080 and one replica per service."
  }

  # Complementar a scripts/validate-k3s-version.ps1: aqui so o formato e
  # verificado. Arquivos coerentes em formato e divergentes em valor sao
  # detectados pela comparacao literal feita no CI.
  assert {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", local.official.kubernetes.k3sVersion))
    error_message = "config/official.yml kubernetes.k3sVersion must follow the vX.Y.Z+k3sN format."
  }

  assert {
    condition     = var.k3s_version == local.official.kubernetes.k3sVersion
    error_message = "TF_VAR_k3s_version must match config/official.yml kubernetes.k3sVersion."
  }

  assert {
    condition     = can(regex("^https://raw\\.githubusercontent\\.com/k3s-io/k3s/[0-9a-f]{40}/install\\.sh$", local.official.kubernetes.installerUrl))
    error_message = "kubernetes.installerUrl must point to install.sh at a fixed 40-character commit SHA."
  }

  assert {
    condition     = can(regex("^[0-9a-f]{64}$", local.official.kubernetes.installerSha256)) && can(regex("^[0-9a-f]{64}$", local.official.kubernetes.binarySha256))
    error_message = "kubernetes.installerSha256 and kubernetes.binarySha256 must be 64-character SHA-256 digests."
  }

  assert {
    condition     = length(local.ecr_repositories) == 4
    error_message = "Exactly four ECR repositories are required: three services and database bootstrap."
  }

  assert {
    condition     = length(local.services) == 3
    error_message = "Exactly three Kubernetes service contracts are required."
  }

  assert {
    condition     = length(distinct(local.node_ports)) == 3
    error_message = "Each service must declare a distinct NodePort."
  }

  assert {
    condition     = alltrue([for port in local.node_ports : port >= 30000 && port <= 32767])
    error_message = "NodePorts must fall inside the 30000-32767 range."
  }

  assert {
    condition     = local.official.loadBalancer.readinessPath == "/ready" && local.official.loadBalancer.healthPath == "/health"
    error_message = "Load balancer contract must keep /health for liveness routing and /ready for target group health checks."
  }

  assert {
    condition     = alltrue([for service in local.services : startswith(service.target_group_name, "oficina-k8s-")])
    error_message = "Target group names must use the oficina-k8s- prefix."
  }
}
