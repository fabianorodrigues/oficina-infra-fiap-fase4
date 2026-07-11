# Non-sensitive outputs published to SSM for other stacks and validators. String
# type only; no SecureString, no secrets, no request data.
resource "aws_ssm_parameter" "outputs" {
  for_each = {
    (local.entrypoint.ssmOutputs.apiId)           = aws_apigatewayv2_api.this.id
    (local.entrypoint.ssmOutputs.apiUrl)          = aws_apigatewayv2_stage.default.invoke_url
    (local.entrypoint.ssmOutputs.apiExecutionArn) = aws_apigatewayv2_api.this.execution_arn
    (local.entrypoint.ssmOutputs.stage)           = aws_apigatewayv2_stage.default.name
    (local.entrypoint.ssmOutputs.vpcLinkId)       = aws_apigatewayv2_vpc_link.this.id
  }

  name  = each.key
  type  = "String"
  value = each.value

  tags = local.common_tags
}
