resource "aws_cloudwatch_log_group" "api" {
  # checkov:skip=CKV_AWS_158:AWS Academy provisions no customer-managed KMS key; the access log group uses default CloudWatch encryption. Access logs are sanitized and contain no secrets.
  # checkov:skip=CKV_AWS_338:Academic retention is 14 days per config/entrypoint.json; multi-year retention is out of scope for this lab.
  name              = local.entrypoint.logging.logGroupName
  retention_in_days = local.entrypoint.logging.retentionInDays

  tags = merge(local.common_tags, { Name = local.entrypoint.logging.logGroupName })
}

locals {
  # Sanitized JSON access log format. Deliberately excludes Authorization, JWT,
  # request/response bodies and the authorizer CPF claim. Only operational fields.
  access_log_format = jsonencode({
    requestId               = "$context.requestId"
    routeKey                = "$context.routeKey"
    status                  = "$context.status"
    responseLength          = "$context.responseLength"
    integrationStatus       = "$context.integrationStatus"
    integrationErrorMessage = "$context.integrationErrorMessage"
    authorizerError         = "$context.authorizer.error"
    sourceIp                = "$context.identity.sourceIp"
    userAgent               = "$context.identity.userAgent"
    requestTime             = "$context.requestTime"
    responseLatency         = "$context.responseLatency"
    integrationLatency      = "$context.integrationLatency"
  })
}
