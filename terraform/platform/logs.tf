resource "aws_cloudwatch_log_group" "service" {
  #checkov:skip=CKV_AWS_158:CloudWatch managed encryption is acceptable for this non-sensitive application log group in the course environment.
  #checkov:skip=CKV_AWS_338:Retention is intentionally configurable and defaults to 14 days to control lab cost.

  for_each = local.services

  name              = each.value.log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = each.value.log_group_name })
}

resource "aws_cloudwatch_log_group" "db_bootstrap" {
  #checkov:skip=CKV_AWS_158:CloudWatch managed encryption is acceptable for this non-sensitive bootstrap log group in the course environment.
  #checkov:skip=CKV_AWS_338:Retention is intentionally configurable and defaults to 14 days to control lab cost.

  name              = "/ecs/oficina/db-bootstrap"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = "/ecs/oficina/db-bootstrap" })
}
