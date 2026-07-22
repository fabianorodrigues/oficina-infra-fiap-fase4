# Allow API Gateway to invoke the Auth CPF live alias, restricted to this API and
# the login route.
resource "aws_lambda_permission" "auth_cpf" {
  statement_id  = "AllowOficinaApiInvokeAuthCpf"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_ssm_parameter.auth_cpf_function_name.value
  qualifier     = local.entrypoint.auth.alias
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/POST/api/auth/cpf"
}

# Compatibility permission scoped to this HTTP API. API Gateway returns 500
# whenever Lambda invoke permission does not match the runtime source ARN; this
# keeps the route-level permission above while covering default-stage/route ARN
# variations without exposing the alias to any other API.
resource "aws_lambda_permission" "auth_cpf_api" {
  statement_id  = "AllowOficinaApiInvokeAuthCpfApi"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_ssm_parameter.auth_cpf_function_name.value
  qualifier     = local.entrypoint.auth.alias
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*"
}

# Allow API Gateway to invoke the Authorizer live alias, restricted to this API's
# authorizer only.
resource "aws_lambda_permission" "authorizer" {
  statement_id  = "AllowOficinaApiInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_ssm_parameter.authorizer_function_name.value
  qualifier     = local.entrypoint.auth.alias
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.jwt.id}"
}

# API-scoped fallback for the same authorizer alias. Still limited to this HTTP
# API, but tolerant of API Gateway source ARN differences for authorizer invokes.
resource "aws_lambda_permission" "authorizer_api" {
  statement_id  = "AllowOficinaApiInvokeAuthorizerApi"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_ssm_parameter.authorizer_function_name.value
  qualifier     = local.entrypoint.auth.alias
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*"
}
