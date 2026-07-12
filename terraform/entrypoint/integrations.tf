# Private integration for protected ALB routes. Overwrites the backend path and
# injects trusted identity headers from the authorizer context. Client-sent
# identity headers cannot survive because these are overwrite (not append).
resource "aws_apigatewayv2_integration" "alb_protected" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  integration_uri        = data.aws_lb_listener.internal.arn
  payload_format_version = local.entrypoint.integration.albPayloadFormatVersion
  timeout_milliseconds   = local.integration_timeout
  request_parameters     = local.protected_request_parameters
}

# Private integration for explicitly public ALB routes (orcamentos acoes-externas).
# Strips any client-sent identity header so no trusted identity can be spoofed.
resource "aws_apigatewayv2_integration" "alb_public" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  integration_uri        = data.aws_lb_listener.internal.arn
  payload_format_version = local.entrypoint.integration.albPayloadFormatVersion
  timeout_milliseconds   = local.integration_timeout
  request_parameters     = local.public_request_parameters
}

# One private integration per health target. Rewrites path to /health and sets
# the trusted internal header the ALB uses to pick the correct backend.
resource "aws_apigatewayv2_integration" "health" {
  for_each = local.health_targets

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  integration_uri        = data.aws_lb_listener.internal.arn
  payload_format_version = local.entrypoint.integration.albPayloadFormatVersion
  timeout_milliseconds   = local.integration_timeout

  request_parameters = merge(
    local.health_base_request_parameters,
    { "overwrite:header.${local.entrypoint.health.targetHeader}" = each.value },
  )
}

# Direct Lambda proxy integration for the login route. Uses the live alias, not
# $LATEST, and never routes login through the ALB.
resource "aws_apigatewayv2_integration" "auth_lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = data.aws_ssm_parameter.auth_cpf_alias_arn.value
  payload_format_version = local.entrypoint.integration.lambdaPayloadFormatVersion
  timeout_milliseconds   = local.integration_timeout
}
