# HTTP API v2. No $default route, no catch-all target, no WebSocket route
# selection expression. Only the stage is named $default.
resource "aws_apigatewayv2_api" "this" {
  name                         = local.api_name
  protocol_type                = "HTTP"
  disable_execute_api_endpoint = local.entrypoint.api.disableExecuteApiEndpoint

  dynamic "cors_configuration" {
    for_each = local.cors_configuration
    content {
      allow_origins     = cors_configuration.value.allow_origins
      allow_methods     = cors_configuration.value.allow_methods
      allow_headers     = cors_configuration.value.allow_headers
      expose_headers    = cors_configuration.value.expose_headers
      allow_credentials = cors_configuration.value.allow_credentials
      max_age           = cors_configuration.value.max_age
    }
  }

  tags = merge(local.common_tags, { Name = local.api_name })
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = local.entrypoint.api.stageName
  auto_deploy = local.entrypoint.api.autoDeploy

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format          = local.access_log_format
  }

  default_route_settings {
    detailed_metrics_enabled = local.entrypoint.logging.detailedMetricsEnabled
    throttling_rate_limit    = local.entrypoint.throttling.rateLimit
    throttling_burst_limit   = local.entrypoint.throttling.burstLimit
  }

  tags = merge(local.common_tags, { Name = "oficina-api-default-stage" })
}
