locals {
  official          = yamldecode(file("${path.module}/../../config/official.yml"))
  resource_contract = yamldecode(file("${path.module}/../../config/resource-contract.yml"))

  project_name   = local.official.project.name
  cluster_name   = local.official.ecs.name
  container_port = local.official.ecs.containerPort

  ecr_repositories = {
    cadastro     = local.official.ecr.cadastro
    estoque      = local.official.ecr.estoque
    ordens       = local.official.ecr.ordens
    db_bootstrap = local.official.ecr.dbBootstrap
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

  services = {
    cadastro = {
      name              = local.official.services.cadastro.name
      target_group_name = local.official.services.cadastro.targetGroupName
      log_group_name    = local.official.services.cadastro.logGroupName
      path_patterns     = ["/api/clientes", "/api/clientes/*", "/api/veiculos", "/api/veiculos/*", "/api/servicos", "/api/servicos/*", "/api/admin/funcionarios", "/api/admin/funcionarios/*", "/api/internal/clientes", "/api/internal/clientes/*", "/api/internal/veiculos", "/api/internal/veiculos/*", "/api/internal/servicos", "/api/internal/servicos/*"]
      health_target     = "cadastro"
      priority_base     = 100
    }
    estoque = {
      name              = local.official.services.estoque.name
      target_group_name = local.official.services.estoque.targetGroupName
      log_group_name    = local.official.services.estoque.logGroupName
      path_patterns     = ["/api/estoque", "/api/estoque/*", "/api/insumos", "/api/insumos/*", "/api/pecas", "/api/pecas/*", "/api/internal/estoque", "/api/internal/estoque/*", "/api/internal/materiais", "/api/internal/materiais/*"]
      health_target     = "estoque"
      priority_base     = 200
    }
    ordens = {
      name              = local.official.services.ordens.name
      target_group_name = local.official.services.ordens.targetGroupName
      log_group_name    = local.official.services.ordens.logGroupName
      path_patterns     = ["/api/ordens-servico", "/api/ordens-servico/*", "/api/minhas-ordens-servico", "/api/minhas-ordens-servico/*", "/api/orcamentos", "/api/orcamentos/*", "/api/meus-orcamentos", "/api/meus-orcamentos/*", "/api/relatorios", "/api/relatorios/*", "/api/webhooks/payments", "/api/webhooks/payments/*"]
      health_target     = "ordens"
      priority_base     = 300
    }
  }

  service_path_rules = merge([
    for service_key, service in local.services : {
      for idx, pattern in service.path_patterns : "${service_key}-${idx}" => {
        service_key  = service_key
        path_pattern = pattern
        priority     = service.priority_base + 10 + idx
      }
    }
  ]...)

  rds_port = 1433

  common_tags = {
    Project    = local.project_name
    ManagedBy  = "terraform"
    Repository = "oficina-infra-fiap-fase4"
  }
}
