data "aws_partition" "current" {}

data "aws_ssm_parameter" "vpc_id" {
  name = local.resource_contract.inputs.vpcId
}

data "aws_ssm_parameter" "private_subnet_1" {
  name = local.resource_contract.inputs.privateSubnet1
}

data "aws_ssm_parameter" "private_subnet_2" {
  name = local.resource_contract.inputs.privateSubnet2
}

data "aws_ssm_parameter" "rds_master_secret_arn" {
  name = local.resource_contract.inputs.rdsMasterSecretArn
}

data "aws_secretsmanager_secret" "sql" {
  for_each = {
    cadastro_runtime  = local.secret_names.cadastro_runtime
    cadastro_migrator = local.secret_names.cadastro_migrator
    estoque_runtime   = local.secret_names.estoque_runtime
    estoque_migrator  = local.secret_names.estoque_migrator
    ordens_runtime    = local.secret_names.ordens_runtime
    ordens_migrator   = local.secret_names.ordens_migrator
    auth_database     = local.secret_names.auth_database
  }

  name = each.value
}
