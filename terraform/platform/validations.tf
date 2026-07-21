check "official_platform_contract" {
  assert {
    condition     = local.project_name == "oficina"
    error_message = "config/official.yml project.name must be oficina."
  }

  assert {
    condition     = local.cluster_name == "oficina"
    error_message = "ECS cluster name must be oficina."
  }

  assert {
    condition     = local.official.ecs.launchType == "FARGATE" && local.official.ecs.desiredCount == 1 && local.container_port == 8080
    error_message = "ECS baseline must be FARGATE, desired count 1 and container port 8080."
  }

  assert {
    condition     = length(local.ecr_repositories) == 4
    error_message = "Exactly four ECR repositories are required: three services and database bootstrap."
  }

  assert {
    condition     = length(local.services) == 3
    error_message = "Exactly three ECS service contracts are required."
  }
}
