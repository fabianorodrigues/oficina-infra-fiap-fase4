resource "aws_cloudwatch_log_group" "service" {
  for_each = local.services

  name              = each.value.log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = each.value.log_group_name })
}

resource "aws_cloudwatch_log_group" "db_bootstrap" {
  name              = "/ecs/oficina/db-bootstrap"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = "/ecs/oficina/db-bootstrap" })
}
