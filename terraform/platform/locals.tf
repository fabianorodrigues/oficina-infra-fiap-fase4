locals {
  official          = yamldecode(file("${path.module}/../../config/official.yml"))
  resource_contract = yamldecode(file("${path.module}/../../config/resource-contract.yml"))

  project_name     = local.official.project.name
  cluster_name     = local.official.cluster.name
  namespace        = local.official.cluster.namespace
  enable_new_relic = local.official.observability.enableNewRelic

  platform_iam_roles = {
    eks_cluster_role_arn              = trimspace(var.platform_iam_roles.eks_cluster_role_arn)
    eks_node_group_role_arn           = trimspace(var.platform_iam_roles.eks_node_group_role_arn)
    load_balancer_controller_role_arn = trimspace(var.platform_iam_roles.load_balancer_controller_role_arn)
    workload_role_arn                 = trimspace(var.platform_iam_roles.workload_role_arn)
  }

  use_external_cluster_role                  = local.platform_iam_roles.eks_cluster_role_arn != ""
  use_external_node_group_role               = local.platform_iam_roles.eks_node_group_role_arn != ""
  use_external_load_balancer_controller_role = local.platform_iam_roles.load_balancer_controller_role_arn != ""
  use_external_workload_role                 = local.platform_iam_roles.workload_role_arn != ""
  use_pod_identity_agent                     = local.use_external_load_balancer_controller_role || local.use_external_workload_role

  ecr_repositories = {
    cadastro = local.official.ecr.cadastro
    estoque  = local.official.ecr.estoque
    ordens   = local.official.ecr.ordens
  }

  sqs_queues = {
    estoque_comandos = {
      name     = "oficina-estoque-comandos.fifo"
      dlq_name = "oficina-estoque-comandos-dlq.fifo"
    }
    ordens_eventos = {
      name     = "oficina-ordens-eventos.fifo"
      dlq_name = "oficina-ordens-eventos-dlq.fifo"
    }
  }

  secret_names = {
    cadastro_runtime  = local.resource_contract.secrets.cadastroRuntimeDb
    cadastro_migrator = local.resource_contract.secrets.cadastroMigrationDb
    estoque_runtime   = local.resource_contract.secrets.estoqueRuntimeDb
    estoque_migrator  = local.resource_contract.secrets.estoqueMigrationDb
    ordens_runtime    = local.resource_contract.secrets.ordensRuntimeDb
    ordens_migrator   = local.resource_contract.secrets.ordensMigrationDb
    auth_database     = local.resource_contract.secrets.authDatabase
    new_relic         = local.resource_contract.secrets.newRelic
  }

  workload_service_accounts = {
    cadastro-runtime = {
      secret_names = [local.secret_names.cadastro_runtime]
      sqs_receive  = []
      sqs_send     = []
    }
    cadastro-migrator = {
      secret_names = [local.secret_names.cadastro_migrator]
      sqs_receive  = []
      sqs_send     = []
    }
    estoque-runtime = {
      secret_names = [local.secret_names.estoque_runtime]
      sqs_receive  = ["estoque_comandos"]
      sqs_send     = ["ordens_eventos", "estoque_comandos_dlq"]
    }
    estoque-migrator = {
      secret_names = [local.secret_names.estoque_migrator]
      sqs_receive  = []
      sqs_send     = []
    }
    ordens-runtime = {
      secret_names = [local.secret_names.ordens_runtime]
      sqs_receive  = ["ordens_eventos"]
      sqs_send     = ["estoque_comandos", "ordens_eventos_dlq"]
    }
    ordens-migrator = {
      secret_names = [local.secret_names.ordens_migrator]
      sqs_receive  = []
      sqs_send     = []
    }
    db-bootstrap = {
      secret_names = [
        local.resource_contract.inputs.rdsMasterSecretArn,
        local.secret_names.cadastro_runtime,
        local.secret_names.cadastro_migrator,
        local.secret_names.estoque_runtime,
        local.secret_names.estoque_migrator,
        local.secret_names.ordens_runtime,
        local.secret_names.ordens_migrator,
        local.secret_names.auth_database
      ]
      sqs_receive = []
      sqs_send    = []
    }
  }

  addon_names = toset(concat(
    [
      "vpc-cni",
      "coredns",
      "kube-proxy"
    ],
    local.use_pod_identity_agent ? ["eks-pod-identity-agent"] : []
  ))

  common_tags = {
    Project    = local.project_name
    ManagedBy  = "terraform"
    Repository = "oficina-infra-fiap-fase4"
  }

  eks_cluster_role_arn = (
    local.use_external_cluster_role
    ? local.platform_iam_roles.eks_cluster_role_arn
    : aws_iam_role.eks_cluster[0].arn
  )

  eks_node_group_role_arn = (
    local.use_external_node_group_role
    ? local.platform_iam_roles.eks_node_group_role_arn
    : aws_iam_role.node_group[0].arn
  )

  workload_role_arn_by_service_account = {
    for key in keys(local.workload_service_accounts) : key => local.platform_iam_roles.workload_role_arn
    if local.use_external_workload_role
  }
}
