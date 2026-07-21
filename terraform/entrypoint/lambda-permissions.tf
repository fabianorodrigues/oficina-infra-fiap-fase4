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
