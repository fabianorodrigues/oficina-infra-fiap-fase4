locals {
  official          = yamldecode(file("${path.module}/../../config/official.yml"))
  resource_contract = yamldecode(file("${path.module}/../../config/resource-contract.yml"))

  project_name     = local.official.project.name
  cluster_name     = local.official.cluster.name
  namespace        = local.official.cluster.namespace
  workload_mode    = local.official.workloadIdentity.mode
  enable_new_relic = local.official.observability.enableNewRelic

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

  addon_names = toset([
    "vpc-cni",
    "coredns",
    "kube-proxy",
    "eks-pod-identity-agent"
  ])

  common_tags = {
    Project    = local.project_name
    ManagedBy  = "terraform"
    Repository = "oficina-infra-fiap-fase4"
  }
}
