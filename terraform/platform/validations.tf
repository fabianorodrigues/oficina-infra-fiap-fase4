check "official_platform_contract" {
  assert {
    condition     = local.project_name == "oficina"
    error_message = "config/official.yml project.name must be oficina."
  }

  assert {
    condition     = local.cluster_name == "oficina" && local.namespace == "oficina"
    error_message = "Cluster name and namespace must be oficina."
  }

  assert {
    condition     = contains(["pod-identity", "irsa"], local.workload_mode)
    error_message = "workloadIdentity.mode must be pod-identity or irsa."
  }

  assert {
    condition     = length(local.ecr_repositories) == 3
    error_message = "Exactly three ECR repositories are required."
  }
}
