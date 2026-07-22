locals {
  # Lambda invoke URIs for the live aliases published by the Auth stack; these
  # are the API Gateway Lambda proxy/authorizer form, never bare Lambda ARNs.
  lambda_invoke_uri_prefix = "arn:${data.aws_partition.current.partition}:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions"
  auth_cpf_invoke_uri      = "${local.lambda_invoke_uri_prefix}/${data.aws_ssm_parameter.auth_cpf_alias_arn.value}/invocations"
  authorizer_invoke_uri    = "${local.lambda_invoke_uri_prefix}/${data.aws_ssm_parameter.authorizer_alias_arn.value}/invocations"
}

# REQUEST authorizer, payload 2.0, simple responses, no cache (TTL 0). Cache is
# deliberately disabled so a simple allow for one route is not reused elsewhere.
resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id                            = aws_apigatewayv2_api.this.id
  name                              = "oficina-authorizer"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = local.authorizer_invoke_uri
  authorizer_payload_format_version = local.entrypoint.auth.payloadFormatVersion
  enable_simple_responses           = local.entrypoint.auth.enableSimpleResponses
  identity_sources                  = local.entrypoint.auth.identitySources
  authorizer_result_ttl_in_seconds  = local.entrypoint.auth.resultTtlSeconds
}
