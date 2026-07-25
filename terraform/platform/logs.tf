resource "aws_cloudwatch_log_group" "service" {
  #checkov:skip=CKV_AWS_158:No customer-managed KMS key is provisioned; this non-sensitive application log group uses default CloudWatch encryption.
  #checkov:skip=CKV_AWS_338:Retention is configurable and defaults to 14 days; multi-year retention is out of scope for this solution.

  for_each = local.services

  name              = each.value.log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = each.value.log_group_name })
}

resource "aws_cloudwatch_log_group" "db_bootstrap" {
  #checkov:skip=CKV_AWS_158:No customer-managed KMS key is provisioned; this non-sensitive bootstrap log group uses default CloudWatch encryption.
  #checkov:skip=CKV_AWS_338:Retention is configurable and defaults to 14 days; multi-year retention is out of scope for this solution.

  name              = "/ecs/oficina/db-bootstrap"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = "/ecs/oficina/db-bootstrap" })
}
